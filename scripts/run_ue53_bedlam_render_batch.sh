#!/usr/bin/env bash
#SBATCH --job-name=bedlam-render-batch
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=96G
# Configure Slurm output with sbatch --output; paths in #SBATCH directives
# cannot be read from config/local.sh.
#
# Renders every batch listed in linux_mrq_batch_generation_status.json
# (written by run_ue53_create_movie_render_queue_batch.sh), restarting
# UnrealEditor fresh for each batch instead of rendering thousands of
# sequences in one continuous session.
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

echo "Total batches:        $TOTAL_BATCHES"
echo "Rendering batch range: [$BATCH_START_INDEX, $BATCH_END_INDEX)"

SUMMARY_STATUS_PATH="${BEDLAM_RUNTIME_BATCH_SUMMARY_PATH:-$BEDLAM_GENERATED_ASSET_STORE/linux_bedlam_render_batch_status.json}"

SUCCEEDED=()
FAILED=()

for (( batch_index=BATCH_START_INDEX; batch_index<BATCH_END_INDEX; batch_index++ )); do
    queue_asset="${BATCH_ASSETS[$batch_index]}"
    echo "=============================================================="
    echo "Batch $((batch_index + 1))/$TOTAL_BATCHES (index $batch_index): $queue_asset"
    echo "=============================================================="

    RUN_TAG="${SLURM_JOB_ID:-manual}_batch${batch_index}_$(date +%Y%m%d_%H%M%S)"
    export BEDLAM_RUNTIME_PROBE_DIR="${BEDLAM_RUNTIME_PROBE_DIR_BASE:-${BEDLAM_LOG_ROOT:-$PWD/unreal_logs}/bedlam_camera_runtime}/${RUN_TAG}"
    export BEDLAM_RUNTIME_RENDER_DIR="${BEDLAM_RUNTIME_RENDER_DIR:-${BEDLAM_OUTPUT_ROOT:-$PWD/render_outputs}}"
    export BEDLAM_RUNTIME_QUEUE_ASSET="$queue_asset"
    export BEDLAM_RUNTIME_START_DELAY="${BEDLAM_RUNTIME_START_DELAY:-15}"
    export BEDLAM_RUNTIME_FORCE_LOOKAT="${BEDLAM_RUNTIME_FORCE_LOOKAT:-0}"
    export BEDLAM_RUNTIME_TICK_GROUP_FIX="${BEDLAM_RUNTIME_TICK_GROUP_FIX:-0}"
    export BEDLAM_RUNTIME_TICK_PREREQUISITE_FIX="${BEDLAM_RUNTIME_TICK_PREREQUISITE_FIX:-1}"
    export BEDLAM_RUNTIME_RESTORE_UNBAKED="${BEDLAM_RUNTIME_RESTORE_UNBAKED:-0}"
    export BEDLAM_RUNTIME_PRESERVE_BEDLAM_LAYOUT="${BEDLAM_RUNTIME_PRESERVE_BEDLAM_LAYOUT:-1}"
    export BEDLAM_RUNTIME_IMAGE_SPATIAL_SAMPLES="${BEDLAM_RUNTIME_IMAGE_SPATIAL_SAMPLES:-0}"
    export BEDLAM_RUNTIME_IMAGE_TEMPORAL_SAMPLES="${BEDLAM_RUNTIME_IMAGE_TEMPORAL_SAMPLES:-0}"
    export BEDLAM_RUNTIME_WRITE_DONE_MARKERS="${BEDLAM_RUNTIME_WRITE_DONE_MARKERS:-1}"
    export BEDLAM_RUNTIME_NO_TEXTURE_STREAMING="${BEDLAM_RUNTIME_NO_TEXTURE_STREAMING:-1}"

    if [[ -n "${BEDLAM_RUNTIME_START_FRAME:-}" || -n "${BEDLAM_RUNTIME_END_FRAME:-}" ]]; then
        export BEDLAM_RUNTIME_WRITE_DONE_MARKERS=0
    fi

    EXTRA_EXEC_CMDS="${BEDLAM_RUNTIME_EXEC_CMDS:-}"
    if [[ -n "$EXTRA_EXEC_CMDS" ]]; then
        PYTHON_EXEC_CMD="${EXTRA_EXEC_CMDS},py ${RENDER_SCRIPT}"
    else
        PYTHON_EXEC_CMD="py ${RENDER_SCRIPT}"
    fi

    ZEN_DIR="/tmp/${USER}/unreal_zen_5.3.2_${RUN_TAG}"
    DDC_DIR="/tmp/${USER}/unreal_ddc_5.3.2"
    mkdir -p "$ZEN_DIR" "$DDC_DIR" "$BEDLAM_RUNTIME_PROBE_DIR" "$BEDLAM_RUNTIME_RENDER_DIR"

    TEXTURE_STREAMING_ARGS=()
    if [[ "$BEDLAM_RUNTIME_NO_TEXTURE_STREAMING" == "1" ]]; then
        TEXTURE_STREAMING_ARGS+=(-NoTextureStreaming)
    fi

    if "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" \
        "$PROJECT" \
        "$MAP" \
        "-ExecCmds=$PYTHON_EXEC_CMD" \
        -RenderOffscreen \
        -vulkan \
        -unattended \
        -NoSplash \
        "${TEXTURE_STREAMING_ARGS[@]}" \
        -ResX=640 \
        -ResY=360 \
        "-ZenDataPath=$ZEN_DIR" \
        "-LocalDataCachePath=$DDC_DIR" \
        -stdout \
        -FullStdOutLogOutput
    then
        echo "Batch $batch_index completed."
        SUCCEEDED+=("$batch_index")
    else
        exit_code=$?
        echo "ERROR: Batch $batch_index failed (UnrealEditor exit code $exit_code): $queue_asset" >&2
        FAILED+=("$batch_index")
    fi
done

succeeded_json=$(printf '%s\n' "${SUCCEEDED[@]}" | jq -R 'select(length>0) | tonumber' | jq -s '.')
failed_json=$(printf '%s\n' "${FAILED[@]}" | jq -R 'select(length>0) | tonumber' | jq -s '.')
jq -n \
    --argjson total "$TOTAL_BATCHES" \
    --argjson start "$BATCH_START_INDEX" \
    --argjson end "$BATCH_END_INDEX" \
    --argjson succeeded "$succeeded_json" \
    --argjson failed "$failed_json" \
    '{total_batches: $total, attempted_range: [$start, $end], succeeded: $succeeded, failed: $failed}' \
    > "$SUMMARY_STATUS_PATH"

echo "=============================================================="
echo "Batch render summary: $SUMMARY_STATUS_PATH"
echo "  Succeeded: ${#SUCCEEDED[@]}/$((BATCH_END_INDEX - BATCH_START_INDEX))"
echo "  Failed:    ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "  Failed batch indices: ${FAILED[*]}"
    exit 1
fi
echo "All requested batches rendered successfully."
