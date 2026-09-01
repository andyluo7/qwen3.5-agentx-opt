#!/usr/bin/env bash
#SBATCH --job-name=q35-p2737-c12-mr
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=04:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-maxrun-bracket-%j.out

# Exact InferenceX PR #2737 C12 max-running-requests bracket.
# Decode graph capacity remains 24 in all arms. Each arm starts a fresh server,
# runs for 900 seconds, archives independently, and must pass its own evidence
# gates before the next arm is allowed to start.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
archive_root="${ARCHIVE_ROOT:-/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
runner="$shared_root/run_and_archive_node2.sh"
point="$shared_root/run_qwen35_pr2737_c12_exact_point_node2.sh"
duration="${DURATION:-900}"
conc=12
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
expected_warmups=131
control_maxrun="${CONTROL_MAXRUN:-24}"
candidate_maxrun="${CANDIDATE_MAXRUN:-12}"
run_tag="$(date +%Y%m%dT%H%M%S%z)"
summary="$shared_root/qwen35-pr2737-c12-maxrun${control_maxrun}-vs${candidate_maxrun}-${duration}s-aba-${run_tag}.tsv"
decision_path="${summary%.tsv}.decision.txt"

# Exact published references from the two audited InferenceX runners.
reference_mi355x_tput=29878.60324
reference_mi355x_intv=100.76418
target_tput=35854.323888
target_intv=120.917016
reference_c8_tput=19504.46869
reference_c8_intv=153.78368
b200_c12_tput=29755.23348
b200_c12_intv=145.60570
prior_decision="${PRIOR_DECISION:-}"

if [[ -n "$prior_decision" ]]; then
  [[ -f "$prior_decision" ]] || {
    echo "prior decision is missing: $prior_decision" >&2
    exit 3
  }
  if grep -qw 'advance_to_3600s=1' "$prior_decision"; then
    echo "prior candidate already qualified; skipping fallback bracket"
    exit 0
  fi
fi

[[ "${SLURM_GPUS_ON_NODE:-}" == 2 ]] || {
  echo "expected exactly two allocated GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
for value in "$duration" "$graph_max_bs" "$control_maxrun" "$candidate_maxrun"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "duration, graph size, and max-running values must be positive integers" >&2
    exit 2
  }
done
[[ "$control_maxrun" != "$candidate_maxrun" ]] || {
  echo "control and candidate max-running values must differ" >&2
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
for attempt in $(seq 1 60); do
  dirty=0
  ss -ltn 2>/dev/null | grep -q ':8888 ' && dirty=1
  fuser /dev/kfd >/tmp/qwen35-pr2737-c12-bracket-kfd-users 2>/dev/null && dirty=1
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

run_arm() {
  local maxrun="$1"
  local label="$2"
  local arm_tag result archive aggregate profile startup_count cancelled
  arm_tag="$(date +%Y%m%dT%H%M%S%z)"
  result="qwen35_pr2737_tp2ep1_c12_exact_maxrun${maxrun}_graph24_${label}_900s_${arm_tag}"
  archive="$archive_root/$result"

  wait_clean
  printf '%s arm_start label=%s max_running_requests=%s graph_max_bs=%s result=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$maxrun" "$graph_max_bs" "$result"

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
    return 1
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
  startup_count="$(grep -Ec 'Uvicorn running on' "$archive/server.log" || true)"
  [[ "$startup_count" == 1 ]]
  if grep -REiq \
    'HIP error|illegal memory access|device-side assert|HSA_STATUS_ERROR_EXCEPTION|EngineDeadError|GPU fault|page fault' \
    "$archive/server.log" "$archive/benchmark.log" "$archive/driver.log" \
    "$archive/aiperf_artifacts/logs/aiperf.log"; then
    echo "fatal runtime signature found in $archive" >&2
    return 1
  fi

  wait_clean
  validate_teardown "$archive/teardown.txt"
  cancelled="$(jq -r '.was_cancelled' "$profile")"
  jq -r \
    --arg label "$label" \
    --arg archive "$archive" \
    --arg cancelled "$cancelled" \
    --argjson maxrun "$maxrun" '
      [$label,
       ($maxrun | tostring),
       (.request_metrics.throughput.per_gpu.total_tput_tps | tostring),
       (.request_metrics.latency.full_response_intvty.p90 | tostring),
       (.request_metrics.throughput.duration_seconds | tostring),
       (.request_accounting.records_profiled | tostring),
       (.request_accounting.records_warmup_dropped | tostring),
       (.request_accounting.records_error_dropped | tostring),
       (.avg_power_w | tostring),
       ($cancelled | tostring),
       $archive] | @tsv
    ' "$aggregate" | tee -a "$summary"
  printf '%s arm_done label=%s max_running_requests=%s archive=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$maxrun" "$archive"
}

printf 'label\tmax_running_requests\tthroughput_per_gpu\tp90_interactivity\tduration_seconds\tprofiled\twarmups\terrors\tavg_power_w\twas_cancelled\tarchive\n' >"$summary"
printf '%s campaign_start job_id=%s duration=%s control_maxrun=%s candidate_maxrun=%s graph_max_bs=%s target_tput=%s target_intv=%s summary=%s\n' \
  "$(date --iso-8601=seconds)" "$job_id" "$duration" "$control_maxrun" \
  "$candidate_maxrun" "$graph_max_bs" "$target_tput" "$target_intv" "$summary"

run_arm "$control_maxrun" control1
run_arm "$candidate_maxrun" candidate
run_arm "$control_maxrun" control2
wait_clean

read -r c1_tput c1_intv < <(awk -F '\t' '$1 == "control1" {print $3, $4}' "$summary")
read -r cand_tput cand_intv < <(awk -F '\t' '$1 == "candidate" {print $3, $4}' "$summary")
read -r c2_tput c2_intv < <(awk -F '\t' '$1 == "control2" {print $3, $4}' "$summary")

awk \
  -v c1t="$c1_tput" -v c1i="$c1_intv" \
  -v ct="$cand_tput" -v ci="$cand_intv" \
  -v c2t="$c2_tput" -v c2i="$c2_intv" \
  -v rt="$reference_mi355x_tput" -v ri="$reference_mi355x_intv" \
  -v tt="$target_tput" -v ti="$target_intv" \
  -v c8t="$reference_c8_tput" -v c8i="$reference_c8_intv" \
  -v bt="$b200_c12_tput" -v bi="$b200_c12_intv" '
  BEGIN {
    control_t = (c1t + c2t) / 2.0
    control_i = (c1i + c2i) / 2.0
    improves_both_controls_t = (ct > c1t && ct > c2t)
    improves_both_controls_i = (ci > c1i && ci > c2i)
    meets_tput_target = (ct >= tt)
    meets_intv_target = (ci >= ti)
    objective_with_repeatability = \
      ((meets_tput_target && improves_both_controls_t) || \
       (meets_intv_target && improves_both_controls_i))
    not_dominated_by_c8 = (ct > c8t || ci > c8i)
    not_dominated_by_controls = \
      !((ct <= c1t && ci <= c1i) || (ct <= c2t && ci <= c2i))
    pareto_relevant = (not_dominated_by_c8 && not_dominated_by_controls)
    advance_to_3600s = (objective_with_repeatability && pareto_relevant)
    printf "control_tput_mean=%.5f candidate_tput=%.5f throughput_vs_control_pct=%.6f throughput_vs_reference_pct=%.6f throughput_target=%.5f meets_tput_target=%d improves_both_controls_tput=%d\n", control_t, ct, 100.0 * (ct / control_t - 1.0), 100.0 * (ct / rt - 1.0), tt, meets_tput_target, improves_both_controls_t
    printf "control_intv_mean=%.5f candidate_intv=%.5f intv_vs_control_pct=%.6f intv_vs_reference_pct=%.6f intv_target=%.5f meets_intv_target=%d improves_both_controls_intv=%d\n", control_i, ci, 100.0 * (ci / control_i - 1.0), 100.0 * (ci / ri - 1.0), ti, meets_intv_target, improves_both_controls_i
    printf "candidate_vs_b200_tput_pct=%.6f candidate_vs_b200_intv_pct=%.6f not_dominated_by_c8=%d not_dominated_by_controls=%d pareto_relevant=%d objective_with_repeatability=%d advance_to_3600s=%d\n", 100.0 * ct / bt, 100.0 * ci / bi, not_dominated_by_c8, not_dominated_by_controls, pareto_relevant, objective_with_repeatability, advance_to_3600s
  }' | tee "$decision_path"

printf '%s campaign_done summary=%s decision=%s\n' \
  "$(date --iso-8601=seconds)" "$summary" "$decision_path"
