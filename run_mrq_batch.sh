#!/usr/bin/env bash
#SBATCH --job-name=bedlam-mrq-batch
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=96G
#SBATCH --time=01:00:00

set -euo pipefail

source args.sh

BEDLAM_MRQ_OUTPUT_DIR="$DATASET" \
BEDLAM_GENERATED_ASSET_STORE="$ASSETS" \
BEDLAM_MRQ_PRESET=1-1-1_EXR_PNG_DepthMask \
BEDLAM_MRQ_RESOLUTION=128x128 \
BEDLAM_MRQ_LEGACY_MOTION_BLUR=false \
BEDLAM_MRQ_NUM_BATCHES=20 \
BEDLAM_MRQ_START_SEQUENCE_INDEX=896 \
scripts/run_ue53_create_movie_render_queue_batch.sh