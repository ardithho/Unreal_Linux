#!/usr/bin/env bash
#SBATCH --job-name=bedlam-render-batch
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=96G
# Configure Slurm output with sbatch --output; paths in #SBATCH directives
# cannot be read from config/local.sh. Request more GPUs on the sbatch
# command line (e.g. --gres=gpu:2) to enable the parallelism below; the
# #SBATCH default above only requests one.
#
# Renders every batch listed in linux_mrq_batch_generation_status.json
# (written by run_ue53_create_movie_render_queue_batch.sh), restarting
# UnrealEditor fresh for each batch instead of rendering thousands of
# sequences in one continuous session.
#
# If more than one GPU is visible in the allocation, batches are split
# round-robin across that many concurrent UnrealEditor processes, each
# pinned to one physical GPU via CUDA_VISIBLE_DEVICES (the NVIDIA driver
# also honors this for Vulkan device enumeration, not just CUDA). This is
# UNVERIFIED on this cluster -- confirm with `nvidia-smi` during a run that
# each process actually lands on its assigned GPU before trusting it for a
# real job. Override the detected count with BEDLAM_RUNTIME_NUM_GPUS, or
# force single-GPU sequential behavior with BEDLAM_RUNTIME_NUM_GPUS=1.
#
# A failed batch does not abort the run: this script deliberately does not
# use `set -e` around the per-batch UnrealEditor invocation, so one crashed
# batch is recorded and the rest still get attempted. Failed batch indices
# are printed and written to the summary status file; rerun just those with
# BEDLAM_RUNTIME_BATCH_START_INDEX / BEDLAM_RUNTIME_BATCH_LIMIT.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/load_config.sh"
load_bedlam_config

UE_ROOT="${UE_ROOT:-}"
PROJECT="${PROJECT:-}"
MAP="${MAP:-}"
RENDER_SCRIPT="${RENDER_SCRIPT:-$REPO_ROOT/python/render_bedlam_mrq.py}"
require_bedlam_setting UE_ROOT || exit 2
require_bedlam_setting PROJECT || exit 2
require_bedlam_setting MAP || exit 2
require_bedlam_setting BEDLAM_GENERATED_ASSET_STORE || exit 2

BEDLAM_MRQ_BATCH_STATUS_PATH="${BEDLAM_MRQ_BATCH_STATUS_PATH:-$BEDLAM_GENERATED_ASSET_STORE/linux_mrq_batch_generation_status.json}"
if [[ ! -f "$BEDLAM_MRQ_BATCH_STATUS_PATH" ]]; then
    echo "ERROR: MRQ batch status not found: $BEDLAM_MRQ_BATCH_STATUS_PATH" >&2
    echo "       Run scripts/run_ue53_create_movie_render_queue_batch.sh first." >&2
    exit 1
fi
if ! jq -e '.status == "complete"' "$BEDLAM_MRQ_BATCH_STATUS_PATH" >/dev/null 2>&1; then
    echo "ERROR: MRQ batch status is not complete: $BEDLAM_MRQ_BATCH_STATUS_PATH" >&2
    exit 1
fi

mapfile -t BATCH_ASSETS < <(jq -r '.batches | sort_by(.index) | .[].mrq_asset' "$BEDLAM_MRQ_BATCH_STATUS_PATH")
TOTAL_BATCHES=${#BATCH_ASSETS[@]}
if [[ "$TOTAL_BATCHES" -eq 0 ]]; then
    echo "ERROR: No batches listed in $BEDLAM_MRQ_BATCH_STATUS_PATH" >&2
    exit 1
fi

BATCH_START_INDEX="${BEDLAM_RUNTIME_BATCH_START_INDEX:-0}"
BATCH_LIMIT="${BEDLAM_RUNTIME_BATCH_LIMIT:-0}"
if [[ "$BATCH_START_INDEX" -ge "$TOTAL_BATCHES" ]]; then
    echo "ERROR: BEDLAM_RUNTIME_BATCH_START_INDEX=$BATCH_START_INDEX >= total batches ($TOTAL_BATCHES)" >&2
    exit 2
fi
BATCH_END_INDEX=$TOTAL_BATCHES
if [[ "$BATCH_LIMIT" -gt 0 ]]; then
    BATCH_END_INDEX=$((BATCH_START_INDEX + BATCH_LIMIT))
    if [[ "$BATCH_END_INDEX" -gt "$TOTAL_BATCHES" ]]; then
        BATCH_END_INDEX=$TOTAL_BATCHES
    fi
fi

test -x "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" || { echo "ERROR: UnrealEditor not found/executable: $UE_ROOT" >&2; exit 1; }
test -f "$PROJECT" || { echo "ERROR: Project not found: $PROJECT" >&2; exit 1; }
test -f "$RENDER_SCRIPT" || { echo "ERROR: Render script not found: $RENDER_SCRIPT" >&2; exit 1; }

detect_gpu_count() {
    if [[ -n "${BEDLAM_RUNTIME_NUM_GPUS:-}" ]]; then
        echo "$BEDLAM_RUNTIME_NUM_GPUS"
        return
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        local count
        count="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)"
        if [[ "$count" -gt 0 ]]; then
            echo "$count"
            return
        fi
    fi
    echo 1
}
NUM_GPUS="$(detect_gpu_count)"
if [[ "$NUM_GPUS" -lt 1 ]]; then
    NUM_GPUS=1
fi

# Required for more than one UnrealEditor process to run concurrently in
# this environment.
export ALLOW_PARALLEL_UNREAL=1
BATCHES_IN_RANGE=$((BATCH_END_INDEX - BATCH_START_INDEX))
if [[ "$NUM_GPUS" -gt "$BATCHES_IN_RANGE" ]]; then
    NUM_GPUS="$BATCHES_IN_RANGE"
fi

echo "Total batches:         $TOTAL_BATCHES"
echo "Rendering batch range: [$BATCH_START_INDEX, $BATCH_END_INDEX)"
echo "Parallel GPU lanes:    $NUM_GPUS"

SUMMARY_STATUS_PATH="${BEDLAM_RUNTIME_BATCH_SUMMARY_PATH:-$BEDLAM_GENERATED_ASSET_STORE/linux_bedlam_render_batch_status.json}"

# Captured once, before any worker overwrites its own copy of these env vars
# per batch -- reading the caller-provided base paths after that would pick
# up a previous batch's already-tagged directory instead.
PROBE_DIR_ROOT="${BEDLAM_RUNTIME_PROBE_DIR:-${BEDLAM_LOG_ROOT:-$PWD/unreal_logs}/bedlam_camera_runtime}"
RENDER_DIR_ROOT="${BEDLAM_RUNTIME_RENDER_DIR:-${BEDLAM_OUTPUT_ROOT:-$PWD/render_outputs}}"
BASE_EXEC_CMDS="${BEDLAM_RUNTIME_EXEC_CMDS:-}"
NO_TEXTURE_STREAMING="${BEDLAM_RUNTIME_NO_TEXTURE_STREAMING:-1}"
WRITE_DONE_MARKERS="${BEDLAM_RUNTIME_WRITE_DONE_MARKERS:-1}"
if [[ -n "${BEDLAM_RUNTIME_START_FRAME:-}" || -n "${BEDLAM_RUNTIME_END_FRAME:-}" ]]; then
    WRITE_DONE_MARKERS=0
fi

mkdir -p "/tmp/${USER}"
RESULTS_DIR="$(mktemp -d "/tmp/${USER}/bedlam_render_batch_results.XXXXXX")"
trap 'rm -rf "$RESULTS_DIR"' EXIT

# Renders every batch index assigned to this lane sequentially, restarting
# UnrealEditor between each. Runs as a background job when NUM_GPUS > 1, so
# results are written to a file (lane_result_file) rather than returned --
# background subshells don't share variable state with the parent script.
render_lane() {
    local gpu_index="$1"
    local lane_result_file="$2"
    shift 2
    local batch_index queue_asset run_tag probe_dir render_dir zen_dir ddc_dir
    local exec_cmds texture_streaming_args exit_code

    : > "$lane_result_file"

    for batch_index in "$@"; do
        queue_asset="${BATCH_ASSETS[$batch_index]}"
        echo "=============================================================="
        echo "[GPU $gpu_index] Batch $((batch_index + 1))/$TOTAL_BATCHES (index $batch_index): $queue_asset"
        echo "=============================================================="

        run_tag="${SLURM_JOB_ID:-manual}_gpu${gpu_index}_batch${batch_index}_$(date +%Y%m%d_%H%M%S)"
        probe_dir="$PROBE_DIR_ROOT/${run_tag}"
        render_dir="$RENDER_DIR_ROOT"
        zen_dir="/tmp/${USER}/unreal_zen_5.3.2_${run_tag}"
        ddc_dir="/tmp/${USER}/unreal_ddc_5.3.2"
        mkdir -p "$zen_dir" "$ddc_dir" "$probe_dir" "$render_dir"

        if [[ -n "$BASE_EXEC_CMDS" ]]; then
            exec_cmds="${BASE_EXEC_CMDS},py ${RENDER_SCRIPT}"
        else
            exec_cmds="py ${RENDER_SCRIPT}"
        fi

        texture_streaming_args=()
        if [[ "$NO_TEXTURE_STREAMING" == "1" ]]; then
            texture_streaming_args+=(-NoTextureStreaming)
        fi

        if CUDA_VISIBLE_DEVICES="$gpu_index" \
            BEDLAM_RUNTIME_PROBE_DIR="$probe_dir" \
            BEDLAM_RUNTIME_RENDER_DIR="$render_dir" \
            BEDLAM_RUNTIME_QUEUE_ASSET="$queue_asset" \
            BEDLAM_RUNTIME_START_DELAY="${BEDLAM_RUNTIME_START_DELAY:-15}" \
            BEDLAM_RUNTIME_FORCE_LOOKAT="${BEDLAM_RUNTIME_FORCE_LOOKAT:-0}" \
            BEDLAM_RUNTIME_TICK_GROUP_FIX="${BEDLAM_RUNTIME_TICK_GROUP_FIX:-0}" \
            BEDLAM_RUNTIME_TICK_PREREQUISITE_FIX="${BEDLAM_RUNTIME_TICK_PREREQUISITE_FIX:-1}" \
            BEDLAM_RUNTIME_RESTORE_UNBAKED="${BEDLAM_RUNTIME_RESTORE_UNBAKED:-0}" \
            BEDLAM_RUNTIME_PRESERVE_BEDLAM_LAYOUT="${BEDLAM_RUNTIME_PRESERVE_BEDLAM_LAYOUT:-1}" \
            BEDLAM_RUNTIME_IMAGE_SPATIAL_SAMPLES="${BEDLAM_RUNTIME_IMAGE_SPATIAL_SAMPLES:-0}" \
            BEDLAM_RUNTIME_IMAGE_TEMPORAL_SAMPLES="${BEDLAM_RUNTIME_IMAGE_TEMPORAL_SAMPLES:-0}" \
            BEDLAM_RUNTIME_WRITE_DONE_MARKERS="$WRITE_DONE_MARKERS" \
            "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" \
                "$PROJECT" \
                "$MAP" \
                "-ExecCmds=$exec_cmds" \
                -RenderOffscreen \
                -vulkan \
                -unattended \
                -NoSplash \
                "${texture_streaming_args[@]}" \
                -ResX=640 \
                -ResY=360 \
                "-ZenDataPath=$zen_dir" \
                "-LocalDataCachePath=$ddc_dir" \
                -stdout \
                -FullStdOutLogOutput
        then
            echo "[GPU $gpu_index] Batch $batch_index completed."
            echo "S $batch_index" >> "$lane_result_file"
        else
            exit_code=$?
            echo "[GPU $gpu_index] ERROR: Batch $batch_index failed (UnrealEditor exit code $exit_code): $queue_asset" >&2
            echo "F $batch_index" >> "$lane_result_file"
        fi
    done
}

LANE_PIDS=()
LANE_RESULT_FILES=()
for (( gpu_index=0; gpu_index<NUM_GPUS; gpu_index++ )); do
    lane_batches=()
    for (( batch_index=BATCH_START_INDEX + gpu_index; batch_index<BATCH_END_INDEX; batch_index+=NUM_GPUS )); do
        lane_batches+=("$batch_index")
    done
    if [[ "${#lane_batches[@]}" -eq 0 ]]; then
        continue
    fi

    lane_result_file="$RESULTS_DIR/lane_${gpu_index}.txt"
    LANE_RESULT_FILES+=("$lane_result_file")

    if [[ "$NUM_GPUS" -eq 1 ]]; then
        # No point backgrounding a single lane; run it directly so output
        # interleaving/ordering stays simple for the common single-GPU case.
        render_lane "$gpu_index" "$lane_result_file" "${lane_batches[@]}"
    else
        render_lane "$gpu_index" "$lane_result_file" "${lane_batches[@]}" &
        LANE_PIDS+=("$!")
    fi
done

if [[ "${#LANE_PIDS[@]}" -gt 0 ]]; then
    wait "${LANE_PIDS[@]}"
fi

SUCCEEDED=()
FAILED=()
for lane_result_file in "${LANE_RESULT_FILES[@]}"; do
    [[ -f "$lane_result_file" ]] || continue
    while read -r status idx; do
        [[ -n "$idx" ]] || continue
        if [[ "$status" == "S" ]]; then
            SUCCEEDED+=("$idx")
        else
            FAILED+=("$idx")
        fi
    done < "$lane_result_file"
done

succeeded_json=$(printf '%s\n' "${SUCCEEDED[@]}" | jq -R 'select(length>0) | tonumber' | jq -s 'sort')
failed_json=$(printf '%s\n' "${FAILED[@]}" | jq -R 'select(length>0) | tonumber' | jq -s 'sort')
jq -n \
    --argjson total "$TOTAL_BATCHES" \
    --argjson start "$BATCH_START_INDEX" \
    --argjson end "$BATCH_END_INDEX" \
    --argjson gpus "$NUM_GPUS" \
    --argjson succeeded "$succeeded_json" \
    --argjson failed "$failed_json" \
    '{total_batches: $total, attempted_range: [$start, $end], parallel_gpu_lanes: $gpus, succeeded: $succeeded, failed: $failed}' \
    > "$SUMMARY_STATUS_PATH"

echo "=============================================================="
echo "Batch render summary: $SUMMARY_STATUS_PATH"
echo "  Parallel GPU lanes: $NUM_GPUS"
echo "  Succeeded: ${#SUCCEEDED[@]}/$((BATCH_END_INDEX - BATCH_START_INDEX))"
echo "  Failed:    ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "  Failed batch indices: ${FAILED[*]}"
    exit 1
fi
echo "All requested batches rendered successfully."
