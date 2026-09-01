#!/usr/bin/env bash
#SBATCH --job-name=q35-p2737-c12-confirm
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=01:45:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-confirm-%j.out

# Independent sustained confirmation for a C12 max-running-requests candidate
# that first passed the 900-second control/candidate/control bracket.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
archive_root="${ARCHIVE_ROOT:-/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
runner="$shared_root/run_and_archive_node2.sh"
point="$shared_root/run_qwen35_pr2737_c12_exact_point_node2.sh"
duration="${DURATION:-3600}"
conc=12
maxrun="${MAX_RUNNING_REQUESTS_OVERRIDE:-4}"
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
expected_warmups=131
target_tput=35854.323888
target_intv=120.917016
reference_c8_tput=19504.46869
reference_c8_intv=153.78368
qualification_summary="${QUALIFICATION_SUMMARY:?QUALIFICATION_SUMMARY is required}"
qualification_decision="${QUALIFICATION_DECISION:?QUALIFICATION_DECISION is required}"
run_tag="$(date +%Y%m%dT%H%M%S%z)"
result="qwen35_pr2737_tp2ep1_c12_exact_maxrun${maxrun}_graph${graph_max_bs}_${duration}s_confirm_${run_tag}"
archive="$archive_root/$result"
decision_path="$shared_root/${result}.decision.txt"

[[ "${SLURM_GPUS_ON_NODE:-}" == 2 ]] || {
  echo "expected exactly two allocated GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
for value in "$duration" "$maxrun" "$graph_max_bs"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "duration, max-running, and graph size must be positive integers" >&2
    exit 2
  }
done
[[ "$duration" -ge 3600 ]] || {
  echo "confirmation duration must be at least 3600 seconds" >&2
  exit 2
}
for required in "$runner" "$point"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

[[ -f "$qualification_summary" && -f "$qualification_decision" ]] || {
  echo "qualification artifacts are missing" >&2
  exit 3
}
grep -qw 'advance_to_3600s=1' "$qualification_decision" || {
  echo "900-second bracket did not authorize a 3600-second confirmation" >&2
  exit 3
}
awk -F '\t' -v expected="$maxrun" '
  $1 == "candidate" && $2 == expected {found=1}
  END {exit !found}
' "$qualification_summary" || {
  echo "qualification summary does not contain the expected maxrun-$maxrun candidate" >&2
  exit 3
}

wait_clean() {
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --nodelist="$target_node" bash -s <<'PREFLIGHT'
set -euo pipefail
for attempt in $(seq 1 60); do
  dirty=0
  ss -ltn 2>/dev/null | grep -q ':8888 ' && dirty=1
  fuser /dev/kfd >/tmp/qwen35-pr2737-c12-confirm-kfd-users 2>/dev/null && dirty=1
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
  (( attempt < 60 )) && sleep 5
done
echo "node did not become clean within 300 seconds" >&2
exit 75
PREFLIGHT
}

validate_teardown() {
  local teardown="$1"
  [[ -f "$teardown" ]]
  awk -F= '
    / busy=/ {busy_count++; if (($2 + 0) != 0) bad=1}
    / vram=/ {vram_count++; if (($2 + 0) > 400000000) bad=1}
    END {exit !(busy_count == 8 && vram_count == 8 && !bad)}
  ' "$teardown"
}

wait_clean
printf '%s confirmation_start result=%s duration=%s max_running_requests=%s graph_max_bs=%s\n' \
  "$(date --iso-8601=seconds)" "$result" "$duration" "$maxrun" "$graph_max_bs"

env \
  TARGET_NODE="$target_node" \
  ARCHIVE_ROOT="$archive_root" \
  TRIGGER_JOB=99999999 \
  RESULT_NAME="$result" \
  DURATION="$duration" \
  CONC="$conc" \
  MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun" \
  CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs" \
  bash "$runner" "$job_id" "$result" bash "$point" "$job_id"

aggregate="$(find "$archive" -maxdepth 1 -type f -name '*.json' \
  ! -name power_validation.json \
  ! -name agentic_power_window.json \
  ! -name gpu_metrics_identity.json | head -1)"
profile="$archive/aiperf_artifacts/profile_export_aiperf.json"
[[ -f "$aggregate" && -f "$profile" ]]
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
  --argjson minimum "$((duration - 10))" \
  --argjson conc "$conc" \
  --argjson expected_warmups "$expected_warmups" '
  (.tp == 2)
  and (.ep == 1)
  and (.conc == $conc)
  and (.kv_offloading == "none")
  and (.request_accounting.records_warmup_dropped == $expected_warmups)
  and (.request_accounting.records_profiled > 0)
  and (.request_accounting.records_error_dropped == 0)
  and (.request_metrics.throughput.duration_seconds >= $minimum)
' "$aggregate" >/dev/null
jq -e '
  .metadata.submission_valid == true
  and (.error_summary | length == 0)
  and (.request_count.avg > 0)
' "$profile" >/dev/null

grep -qx "max_running_requests=$maxrun" "$archive/run_identity.txt"
grep -qx "cuda_graph_max_bs=$graph_max_bs" "$archive/run_identity.txt"
grep -Eq -- "--max-running-requests[[:space:]]+${maxrun}([[:space:]]|$)" "$archive/sglang_command.txt"
grep -Eq -- "--cuda-graph-max-bs[[:space:]]+${graph_max_bs}([[:space:]]|$)" "$archive/sglang_command.txt"
grep -Eq -- '--page-size[[:space:]]+16([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- '--max-prefill-tokens[[:space:]]+16384([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- '--chunked-prefill-size[[:space:]]+16384([[:space:]]|$)' "$archive/sglang_command.txt"
grep -Eq -- "'mem_fraction_static': 0.68([,}])" "$archive/server.log"
[[ "$(grep -Ec 'Uvicorn running on' "$archive/server.log" || true)" == 1 ]]
if grep -REiq \
  'HIP error|illegal memory access|device-side assert|HSA_STATUS_ERROR_EXCEPTION|EngineDeadError|GPU fault|page fault' \
  "$archive/server.log" "$archive/benchmark.log" "$archive/driver.log" \
  "$archive/aiperf_artifacts/logs/aiperf.log"; then
  echo "fatal runtime signature found in $archive" >&2
  exit 1
fi

wait_clean
validate_teardown "$archive/teardown.txt"

throughput="$(jq -r '.request_metrics.throughput.per_gpu.total_tput_tps' "$aggregate")"
interactivity="$(jq -r '.request_metrics.latency.full_response_intvty.p90' "$aggregate")"
awk \
  -v t="$throughput" -v i="$interactivity" \
  -v tt="$target_tput" -v ti="$target_intv" \
  -v c8t="$reference_c8_tput" -v c8i="$reference_c8_intv" '
  BEGIN {
    meets_tput = (t >= tt)
    meets_intv = (i >= ti)
    pareto_relevant = (t > c8t || i > c8i)
    objective_met = ((meets_tput || meets_intv) && pareto_relevant)
    printf "throughput_per_gpu=%.5f throughput_target=%.5f meets_tput_target=%d\n", t, tt, meets_tput
    printf "p90_interactivity=%.5f interactivity_target=%.5f meets_intv_target=%d\n", i, ti, meets_intv
    printf "pareto_relevant=%d objective_met=%d\n", pareto_relevant, objective_met
    exit !objective_met
  }' | tee "$decision_path"

printf '%s confirmation_done archive=%s decision=%s\n' \
  "$(date --iso-8601=seconds)" "$archive" "$decision_path"
