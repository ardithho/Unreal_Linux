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
# launched via `srun --exclusive --gres=gpu:1` so Slurm's cgroup device
# plugin restricts that step to exactly one physical GPU. Two app-level
# pinning mechanisms were tried first and BOTH confirmed NOT to affect
# Vulkan device selection in this environment: CUDA_VISIBLE_DEVICES
# (2026-08-26: both lanes landed on the same physical GPU with it) and the
# engine's own `-graphicsadapter=N` launch argument (2026-08-26: same
# failure -- two distinct UnrealEditor PIDs both showed up on GPU 0 in
# `nvidia-smi`). Do not reintroduce either as the pinning mechanism without
# re-testing; cgroup-level device isolation via srun works regardless of
# what the driver/engine does with adapter-index hints, since the other
# GPUs' device nodes simply aren't present in the step's cgroup. Confirm
# with `nvidia-smi` during a run that each srun step actually lands on a
# distinct GPU before trusting this for a real job. Override the detected
# count with BEDLAM_RUNTIME_NUM_GPUS, or force single-GPU sequential
# behavior with BEDLAM_RUNTIME_NUM_GPUS=1.
#
# Each srun step also passes `--exact` with an explicit --cpus-per-task and
# --mem share. Without `--exact`, a step claims all non-GRES resources (all
# CPUs, all memory) of the whole job allocation regardless of
# --cpus-per-task (see `man srun`), so with `--exclusive` a second
# concurrent step just blocks ("step creation ... retrying (Requested nodes
# are busy)") waiting for the first to exit. On 2026-08-26 this burned an
# entire 8-hour job: lane 0 ran, lane 1 never started, and the job was
# killed by the time limit. Do not drop `--exact` from LAUNCH_PREFIX.
#
# A failed batch does not abort the run: this script deliberately does not
# use `set -e` around the per-batch UnrealEditor invocation, so one crashed
# batch is recorded and the rest still get attempted. Failed batch indices
# are printed and written to the summary status file; rerun just those with
# BEDLAM_RUNTIME_BATCH_INDICES="5,7,9" (a comma-separated list of specific,
# possibly non-contiguous indices), or fall back to a contiguous range via
# BEDLAM_RUNTIME_BATCH_START_INDEX / BEDLAM_RUNTIME_BATCH_LIMIT when
# BEDLAM_RUNTIME_BATCH_INDICES is unset.

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

# BEDLAM_RUNTIME_BATCH_INDICES picks specific, possibly non-contiguous
# batches (e.g. "5,7,9" to retry just the ones that stalled/failed) and
# takes precedence over BEDLAM_RUNTIME_BATCH_START_INDEX/_LIMIT, which
# select a contiguous range instead. Either way the result is
# REQUESTED_BATCHES, the sorted, de-duplicated list of indices actually
# rendered below.
REQUESTED_BATCHES=()
if [[ -n "${BEDLAM_RUNTIME_BATCH_INDICES:-}" ]]; then
    IFS=',' read -r -a _raw_indices <<< "$BEDLAM_RUNTIME_BATCH_INDICES"
    for idx in "${_raw_indices[@]}"; do
        idx="${idx// /}"
        [[ -n "$idx" ]] || continue
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
            echo "ERROR: BEDLAM_RUNTIME_BATCH_INDICES has a non-integer entry: '$idx'" >&2
            exit 2
        fi
        if [[ "$idx" -ge "$TOTAL_BATCHES" ]]; then
            echo "ERROR: BEDLAM_RUNTIME_BATCH_INDICES has index $idx >= total batches ($TOTAL_BATCHES)" >&2
            exit 2
        fi
        REQUESTED_BATCHES+=("$idx")
    done
    mapfile -t REQUESTED_BATCHES < <(printf '%s\n' "${REQUESTED_BATCHES[@]}" | sort -nu)
    if [[ "${#REQUESTED_BATCHES[@]}" -eq 0 ]]; then
        echo "ERROR: BEDLAM_RUNTIME_BATCH_INDICES did not contain any valid indices" >&2
        exit 2
    fi
else
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
    for (( idx=BATCH_START_INDEX; idx<BATCH_END_INDEX; idx++ )); do
        REQUESTED_BATCHES+=("$idx")
    done
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
if [[ "$NUM_GPUS" -gt "${#REQUESTED_BATCHES[@]}" ]]; then
    NUM_GPUS="${#REQUESTED_BATCHES[@]}"
fi

LAUNCH_PREFIX=()
if [[ "$NUM_GPUS" -gt 1 ]]; then
    if [[ -z "${SLURM_JOB_ID:-}" ]] || ! command -v srun >/dev/null 2>&1; then
        echo "ERROR: $NUM_GPUS parallel GPU lanes requested but not running inside a Slurm" >&2
        echo "       allocation (or srun is unavailable). Cgroup-based GPU isolation via" >&2
        echo "       srun --gres=gpu:1 is required for correct multi-GPU pinning -- see the" >&2
        echo "       note above render_lane(). Submit via sbatch, or set" >&2
        echo "       BEDLAM_RUNTIME_NUM_GPUS=1 to render sequentially instead." >&2
        exit 2
    fi
    # Give each step an explicit CPU and memory share of the allocation.
    # `--exact` is required for concurrent steps to coexist at all: per
    # `man srun`, WITHOUT it a step claims all non-GRES resources (all CPUs,
    # all memory) of the whole job allocation regardless of --cpus-per-task,
    # so a second `--exclusive` step just blocks ("step creation ... retrying
    # (Requested nodes are busy)") waiting for the first to exit -- which is
    # what happened on 2026-08-26 and burned the full job time limit with
    # lane 1 never starting. `--exact` scopes each step to only what it
    # explicitly requests, freeing the rest of the allocation for siblings.
    LANE_CPUS=$(( ${SLURM_CPUS_PER_TASK:-$NUM_GPUS} / NUM_GPUS ))
    if [[ "$LANE_CPUS" -lt 1 ]]; then
        LANE_CPUS=1
    fi
    LANE_MEM_MB=$(( ${SLURM_MEM_PER_NODE:-0} / NUM_GPUS ))
    LANE_MEM_ARGS=()
    if [[ "$LANE_MEM_MB" -gt 0 ]]; then
        LANE_MEM_ARGS=(--mem="${LANE_MEM_MB}M")
    fi
    LAUNCH_PREFIX=(srun --exclusive --exact --gres=gpu:1 --ntasks=1 --cpus-per-task="$LANE_CPUS" "${LANE_MEM_ARGS[@]}" --cpu-bind=none)
fi

echo "Total batches:         $TOTAL_BATCHES"
echo "Rendering batch indices (${#REQUESTED_BATCHES[@]}): ${REQUESTED_BATCHES[*]}"
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
        # Per-lane, not per-batch: reused across a lane's own sequential
        # batches for cache-hit benefit, but never shared with a
        # concurrently-running lane. A single shared DDC dir let two
        # UnrealEditor processes hit the same filesystem cache lock files at
        # once, which can block one of them indefinitely with zero output
        # and no error (observed 2026-08-27, job 832439: GPU 0's batch sat
        # with a live process and no progress once GPU 1 was truly running
        # concurrently).
        ddc_dir="/tmp/${USER}/unreal_ddc_5.3.2_gpu${gpu_index}"
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

        if BEDLAM_RUNTIME_PROBE_DIR="$probe_dir" \
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
            "${LAUNCH_PREFIX[@]}" \
            "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" \
                "$PROJECT" \
                "$MAP" \
                "-ExecCmds=$exec_cmds" \
                -RenderOffscreen \
                -vulkan \
                -graphicsadapter=0 \
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
    for (( i=gpu_index; i<${#REQUESTED_BATCHES[@]}; i+=NUM_GPUS )); do
        lane_batches+=("${REQUESTED_BATCHES[i]}")
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
attempted_json=$(printf '%s\n' "${REQUESTED_BATCHES[@]}" | jq -R 'select(length>0) | tonumber' | jq -s 'sort')
jq -n \
    --argjson total "$TOTAL_BATCHES" \
    --argjson attempted "$attempted_json" \
    --argjson gpus "$NUM_GPUS" \
    --argjson succeeded "$succeeded_json" \
    --argjson failed "$failed_json" \
    '{total_batches: $total, attempted_batches: $attempted, parallel_gpu_lanes: $gpus, succeeded: $succeeded, failed: $failed}' \
    > "$SUMMARY_STATUS_PATH"

echo "=============================================================="
echo "Batch render summary: $SUMMARY_STATUS_PATH"
echo "  Parallel GPU lanes: $NUM_GPUS"
echo "  Succeeded: ${#SUCCEEDED[@]}/${#REQUESTED_BATCHES[@]}"
echo "  Failed:    ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "  Failed batch indices: ${FAILED[*]}"
    exit 1
fi
echo "All requested batches rendered successfully."
