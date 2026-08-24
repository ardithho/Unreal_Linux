#!/usr/bin/env bash
#SBATCH --job-name=bedlam-render-batch
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=96G
#SBATCH --time=12:00:00

set -uo pipefail

source args.sh

BEDLAM_GENERATED_ASSET_STORE="$ASSETS" \
BEDLAM_RUNTIME_EXEC_CMDS='tick.AllowAsyncTickDispatch 0,tick.AllowConcurrentTickQueue 0' \
scripts/run_ue53_bedlam_render_batch.sh