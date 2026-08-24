#!/usr/bin/env bash
#SBATCH --job-name=bedlam-pipeline
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=96G
#SBATCH --time=08:00:00

set -euo pipefail

source args.sh

scripts/run_ue53_csv_to_mrq_workflow.sh \
  --engine "$UE_ROOT" \
  --project "$PROJECT" \
  --map "$MAP" \
  --map-file "$MAP_FILE" \
  --csv "$DATASET/be_seq.csv" \
  --output "$DATASET" \
  --asset-store "$ASSETS" \
  --preset 1-1-1_EXR_PNG_DepthMask \
  --resolution 128x128 \
  --legacy-motion-blur false

scripts/run_ue53_bedlam_render.sh