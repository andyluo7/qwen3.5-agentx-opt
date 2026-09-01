#!/usr/bin/env bash
#SBATCH --job-name=qwen35-pr2737-c12-base
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=01:30:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-base-%j.out

# Allocate exactly the TP width so the in-container AMD power monitor sees
# the same two devices that serve the model. Full CPU and memory allocation
# keeps the node isolated without Slurm expanding an exclusive GPU request to
# all eight devices.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
archive_root="${ARCHIVE_ROOT:-/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
runner="$shared_root/run_and_archive_node2.sh"
point="$shared_root/run_qwen35_pr2737_c12_exact_point_node2.sh"
duration="${DURATION:-120}"
run_tag="$(date +%Y%m%dT%H%M%S%z)"
result="qwen35_pr2737_tp2ep1_c12_exact_maxrun24_graph24_${duration}s_${run_tag}"
archive="$archive_root/$result"

[[ "${SLURM_GPUS_ON_NODE:-}" == 2 ]] || {
  echo "expected an exclusive two-GPU allocation; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
for required in "$runner" "$point"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

wait_clean() {
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --nodelist="$target_node" bash -s <<'PREFLIGHT'
set -euo pipefail
for attempt in $(seq 1 36); do
  dirty=0
  ss -ltn 2>/dev/null | grep -q ':8888 ' && dirty=1
  fuser /dev/kfd >/tmp/qwen35-pr2737-c12-kfd-users 2>/dev/null && dirty=1
  for busy_file in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do
    [[ -r "$busy_file" ]] || continue
    card_dir="${busy_file%/device/gpu_busy_percent}"
    busy="$(<"$busy_file")"
    vram="$(<"$card_dir/device/mem_info_vram_used")"
    if (( busy != 0 || vram > 400000000 )); then
      dirty=1
    fi
  done
  if (( dirty == 0 )); then
    exit 0
  fi
  (( attempt < 36 )) && sleep 5
done
echo "node did not become clean within 180 seconds" >&2
exit 75
PREFLIGHT
}

wait_clean
printf '%s baseline_start result=%s duration=%s\n' \
  "$(date --iso-8601=seconds)" "$result" "$duration"

env \
  TARGET_NODE="$target_node" \
  ARCHIVE_ROOT="$archive_root" \
  TRIGGER_JOB=99999999 \
  RESULT_NAME="$result" \
  DURATION="$duration" \
  CONC=12 \
  MAX_RUNNING_REQUESTS_OVERRIDE=24 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  bash "$runner" "$job_id" "$result" bash "$point" "$job_id"

aggregate="$(find "$archive" -maxdepth 1 -type f -name '*.json' \
  ! -name power_validation.json \
  ! -name agentic_power_window.json \
  ! -name gpu_metrics_identity.json | head -1)"
[[ -f "$aggregate" ]]
[[ -f "$archive/SHA256SUMS.verify" ]]
if grep -q FAILED "$archive/SHA256SUMS.verify"; then
  echo "manifest verification failed in $archive" >&2
  exit 1
fi
jq -e '
  .power_valid == true
  and .expected_gpu_count == 2
  and .observed_gpu_count == 2
  and .accumulator_check.available == true
  and .accumulator_check.within_tolerance == true
' "$archive/power_validation.json" >/dev/null
jq -e \
  --argjson minimum "$((duration - 10))" '
  (.tp == 2)
  and (.ep == 1)
  and (.conc == 12)
  and (.kv_offloading == "none")
  and (.request_accounting.records_warmup_dropped == 131)
  and (.request_accounting.records_profiled > 0)
  and (.request_accounting.records_error_dropped == 0)
  and (.request_metrics.throughput.duration_seconds >= $minimum)
' "$aggregate" >/dev/null
grep -Eq -- '--max-running-requests[[:space:]]+24([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- '--cuda-graph-max-bs[[:space:]]+24([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- '--page-size[[:space:]]+16([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- '--max-prefill-tokens[[:space:]]+16384([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- "'mem_fraction_static': 0.68([,}])" "$archive/server.log"
[[ "$(grep -Ec 'Uvicorn running on' "$archive/server.log" || true)" == 1 ]]
if grep -REiq \
  'HIP error|illegal memory access|device-side assert|HSA_STATUS_ERROR_EXCEPTION|EngineDeadError|GPU fault|page fault' \
  "$archive/server.log" "$archive/benchmark.log" "$archive/aiperf_artifacts/logs/aiperf.log"; then
  echo "fatal runtime signature found in $archive" >&2
  exit 1
fi

wait_clean
jq -r '
  ["throughput_per_gpu", (.request_metrics.throughput.per_gpu.total_tput_tps | tostring)],
  ["p90_interactivity", (.request_metrics.latency.full_response_intvty.p90 | tostring)],
  ["profiled", (.request_accounting.records_profiled | tostring)],
  ["warmups", (.request_accounting.records_warmup_dropped | tostring)],
  ["errors", (.request_accounting.records_error_dropped | tostring)],
  ["duration_seconds", (.request_metrics.throughput.duration_seconds | tostring)],
  ["avg_power_w", (.avg_power_w | tostring)] | @tsv
' "$aggregate"
printf '%s baseline_done archive=%s\n' "$(date --iso-8601=seconds)" "$archive"
