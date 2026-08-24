#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/generated_asset_store.sh"
source "$SCRIPT_DIR/lib/load_config.sh"
load_bedlam_config

UE_ROOT="${UE_ROOT:-}"
PROJECT="${PROJECT:-}"
MAP="${MAP:-}"
MAP_FILE="${MAP_FILE:-}"
WRAPPER="${WRAPPER:-$REPO_ROOT/python/run_create_movie_render_queue_batch.py}"
require_bedlam_setting UE_ROOT
require_bedlam_setting PROJECT
require_bedlam_setting MAP
require_bedlam_setting MAP_FILE
require_bedlam_setting BEDLAM_MRQ_OUTPUT_DIR
require_bedlam_setting BEDLAM_MRQ_NUM_BATCHES

if [[ "$BEDLAM_MRQ_NUM_BATCHES" -lt 1 ]]; then
    echo "ERROR: BEDLAM_MRQ_NUM_BATCHES must be >= 1, got: $BEDLAM_MRQ_NUM_BATCHES" >&2
    exit 2
fi

export BEDLAM_MRQ_GENERATOR_SCRIPT="${BEDLAM_MRQ_GENERATOR_SCRIPT:-$UE_ROOT/Engine/Content/PS/Bedlam/Core/Python/create_movie_render_queue.py}"
export BEDLAM_MRQ_OUTPUT_DIR
export BEDLAM_MRQ_PRESET="${BEDLAM_MRQ_PRESET:-1-1-1_EXR_PNG_DepthMask}"
export BEDLAM_MRQ_RESOLUTION="${BEDLAM_MRQ_RESOLUTION:-1280x720}"
export BEDLAM_MRQ_LEGACY_MOTION_BLUR="${BEDLAM_MRQ_LEGACY_MOTION_BLUR:-false}"
export BEDLAM_MRQ_EXPECTED_MAP="${BEDLAM_MRQ_EXPECTED_MAP:-$MAP}"
export BEDLAM_MRQ_START_DELAY="${BEDLAM_MRQ_START_DELAY:-5}"
export BEDLAM_MRQ_START_TIMEOUT="${BEDLAM_MRQ_START_TIMEOUT:-180}"
export BEDLAM_MRQ_NUM_BATCHES
export BEDLAM_MRQ_START_SEQUENCE_INDEX="${BEDLAM_MRQ_START_SEQUENCE_INDEX:-0}"
export BEDLAM_MRQ_STATUS_DIR="${BEDLAM_MRQ_STATUS_DIR:-$(dirname "$(dirname "$BEDLAM_MRQ_OUTPUT_DIR")")/outputs/$(basename "$BEDLAM_MRQ_OUTPUT_DIR")}"
export BEDLAM_GENERATED_ASSET_STORE="${BEDLAM_GENERATED_ASSET_STORE:-$BEDLAM_MRQ_STATUS_DIR/unreal_assets}"
export BEDLAM_MRQ_LEVEL_SEQUENCE_STATUS="${BEDLAM_MRQ_LEVEL_SEQUENCE_STATUS:-$BEDLAM_GENERATED_ASSET_STORE/linux_level_sequence_status.json}"

PROJECT_DIR="$(dirname "$PROJECT")"
LEVEL_SEQUENCE_PROJECT_DIR="$PROJECT_DIR/Content/Bedlam/LevelSequences"
MOVIE_RENDER_QUEUE_PROJECT_DIR="$PROJECT_DIR/Content/Bedlam/MovieRenderQueue"
ensure_generated_asset_link "$LEVEL_SEQUENCE_PROJECT_DIR" "$BEDLAM_GENERATED_ASSET_STORE/LevelSequences"
ensure_generated_asset_link "$MOVIE_RENDER_QUEUE_PROJECT_DIR" "$BEDLAM_GENERATED_ASSET_STORE/MovieRenderQueue"

RUN_TAG="${SLURM_JOB_ID:-manual}_$(date +%Y%m%d_%H%M%S)"
ZEN_DIR="/tmp/${USER}/unreal_zen_5.3.2_mrq_batch_${RUN_TAG}"
DDC_DIR="/tmp/${USER}/unreal_ddc_5.3.2"
mkdir -p "$ZEN_DIR" "$DDC_DIR" "$BEDLAM_MRQ_OUTPUT_DIR" "$BEDLAM_MRQ_STATUS_DIR"
STATUS_PATH="$BEDLAM_GENERATED_ASSET_STORE/linux_mrq_batch_generation_status.json"
export BEDLAM_MRQ_STATUS_PATH="$STATUS_PATH"
rm -f -- "$STATUS_PATH"

test -x "$UE_ROOT/Engine/Binaries/Linux/UnrealEditor"
test -f "$PROJECT"
test -f "$MAP_FILE"
test -f "$WRAPPER"
test -f "$BEDLAM_MRQ_GENERATOR_SCRIPT"

echo "Project:      $PROJECT"
echo "Map:          $BEDLAM_MRQ_EXPECTED_MAP"
echo "Sequences:    /Game/Bedlam/LevelSequences"
echo "Output:       $BEDLAM_MRQ_OUTPUT_DIR"
echo "Preset:       $BEDLAM_MRQ_PRESET"
echo "Resolution:   $BEDLAM_MRQ_RESOLUTION"
echo "Assets:       $BEDLAM_GENERATED_ASSET_STORE"
echo "Num batches:  $BEDLAM_MRQ_NUM_BATCHES"
echo "Start index:  $BEDLAM_MRQ_START_SEQUENCE_INDEX"

"$UE_ROOT/Engine/Binaries/Linux/UnrealEditor" \
    "$PROJECT" \
    "$MAP_FILE" \
    "-ExecCmds=py $WRAPPER" \
    -RenderOffscreen \
    -vulkan \
    -unattended \
    -NoSplash \
    "-ZenDataPath=$ZEN_DIR" \
    "-LocalDataCachePath=$DDC_DIR" \
    -stdout \
    -FullStdOutLogOutput

if ! grep -q '"status": "complete"' "$STATUS_PATH" 2>/dev/null; then
    echo "ERROR: MRQ batch generation did not complete successfully: $STATUS_PATH" >&2
    test ! -f "$STATUS_PATH" || cat "$STATUS_PATH" >&2
    exit 1
fi
echo "MRQ batch generation completed. Status: $STATUS_PATH"
