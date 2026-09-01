#!/usr/bin/env bash
#SBATCH --job-name=q35-p2737-c12-post
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=8
#SBATCH --time=00:10:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-postflight-%j.out

# Independent full-node postflight after a successful 3600-second confirmation.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
output="$shared_root/qwen35-pr2737-c12-confirm-postflight-${job_id}.txt"

[[ "${SLURM_GPUS_ON_NODE:-}" == 8 ]] || {
  echo "expected all eight GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}

srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --cpus-per-task=1 --nodelist="$target_node" bash -s >"$output" <<'POSTFLIGHT'
set -euo pipefail
date --iso-8601=seconds
echo PORTS
if ss -ltnp 2>/dev/null | grep -E ':8888[[:space:]]'; then
  echo "unexpected port 8888 listener" >&2
  exit 1
fi
echo WORKLOAD_PROCESSES
if pgrep -af 'sglang|aiperf|launch_server|qwen35_pr2737' | grep -vE 'pgrep|postflight'; then
  echo "unexpected workload process" >&2
  exit 1
fi
echo KFD_USERS
if fuser /dev/kfd 2>/dev/null; then
  echo "unexpected /dev/kfd user" >&2
  exit 1
fi
echo GPU_BUSY_VRAM
gpu_count=0
for busy_file in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do
  [[ -r "$busy_file" ]] || continue
  card_dir="${busy_file%/device/gpu_busy_percent}"
  card="${card_dir##*/}"
  busy="$(<"$busy_file")"
  vram="$(<"$card_dir/device/mem_info_vram_used")"
  printf '%s busy=%s\n' "$card" "$busy"
  printf '%s vram=%s\n' "$card" "$vram"
  ((gpu_count += 1))
  (( busy == 0 )) || exit 1
  (( vram <= 400000000 )) || exit 1
done
(( gpu_count == 8 )) || {
  echo "expected eight GPU telemetry records; got $gpu_count" >&2
  exit 1
}
echo RECENT_GPU_FAULTS
faults="$(journalctl -k --since '2 hours ago' --no-pager 2>/dev/null \
  | grep -Ei 'amdgpu.*(fault|reset|ras)|xgmi.*error|page fault|GPU reset|HSA.*error' || true)"
if [[ -n "$faults" ]]; then
  printf '%s\n' "$faults"
  exit 1
fi
echo CLEAN
POSTFLIGHT

cat "$output"
