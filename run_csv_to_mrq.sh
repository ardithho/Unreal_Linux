#!/usr/bin/env bash
#SBATCH --job-name=bedlam-csv-to-mrq
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=96G
#SBATCH --time=02:00:00

set -euo pipefail

source args.sh

BEDLAM_LEVEL_SEQUENCE_CSV_PATH="$DATASET/be_seq.csv" \
BEDLAM_GENERATED_ASSET_STORE="$ASSETS" \
scripts/run_ue53_create_level_sequences.sh

BEDLAM_MRQ_OUTPUT_DIR="$DATASET" \
BEDLAM_GENERATED_ASSET_STORE="$ASSETS" \
BEDLAM_MRQ_PRESET=1-1-1_EXR_PNG_DepthMask \
BEDLAM_MRQ_RESOLUTION=128x128 \
BEDLAM_MRQ_LEGACY_MOTION_BLUR=false \
BEDLAM_MRQ_NUM_BATCHES=20 \
BEDLAM_MRQ_START_SEQUENCE_INDEX=0 \
scripts/run_ue53_create_movie_render_queue_batch.sh
