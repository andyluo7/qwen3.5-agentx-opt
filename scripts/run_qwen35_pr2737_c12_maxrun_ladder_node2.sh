#!/usr/bin/env bash
#SBATCH --job-name=q35-p2737-c12-ladder
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=08:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-maxrun-ladder-%j.out

# Measure the highest-leverage unmeasured exact-PR2737 TP2/EP1 C12
# admission-control settings with submission-valid AgentX runs.
#
# The frozen maxrun-4 point is measured at both ends to expose drift. Candidate
# arms are provisional even when all per-run evidence checks pass. Only points
# selected by the frozen 12-anchor objective evaluator may advance to an
# isolated bracket and subsequent sustained confirmation.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
archive_root="${ARCHIVE_ROOT:-/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
runner="$shared_root/run_and_archive_node2.sh"
point="$shared_root/run_qwen35_pr2737_c12_exact_point_node2.sh"
point_sha256="${POINT_SCRIPT_SHA256:-cb6f1e1526c46176d0326e2a9f05ecfae73a40cf4209f6bbad890eb3a9561bb8}"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:-}"
duration="${DURATION:-900}"
control_maxrun="${CONTROL_MAXRUN:-4}"
candidate_maxruns="${CANDIDATE_MAXRUNS:-2 1 6}"
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
page_size="${PAGE_SIZE_OVERRIDE:-16}"
scheduler_recv_interval="${SCHEDULER_RECV_INTERVAL_OVERRIDE:-30}"
fixed_patch_path="${PATCH_PATH:-}"
fixed_patch_sha256="${PATCH_SHA256:-}"
fixed_aiter_patch_path="${AITER_PATCH_PATH:-}"
fixed_aiter_patch_sha256="${AITER_PATCH_SHA256:-}"
fixed_patch_label="${PATCH_LABEL:-exact}"
expected_route_regex="${EXPECTED_ROUTE_REGEX:-}"
expected_route_regex_2="${EXPECTED_ROUTE_REGEX_2:-}"
expected_route_regex_3="${EXPECTED_ROUTE_REGEX_3:-}"
conc=12
expected_warmups=131
run_tag="$(date +%Y%m%dT%H%M%S%z)"
prefix="$shared_root/qwen35-pr2737-c12-maxrun-ladder-${duration}s-${run_tag}"
summary="$prefix.tsv"
points_jsonl="$prefix.points.jsonl"
manifest="$prefix.candidates.json"
evaluation_json="$prefix.evaluation.json"
decision="$prefix.decision.txt"

[[ "${SLURM_GPUS_ON_NODE:-}" == 2 ]] || {
  echo "expected exactly two allocated GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
for value in \
  "$duration" "$control_maxrun" "$graph_max_bs" "$page_size" \
  "$scheduler_recv_interval"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "duration, control max-running, and graph size must be positive integers" >&2
    exit 2
  }
done
case "$page_size" in
  16|64) ;;
  *)
    echo "PAGE_SIZE_OVERRIDE must be 16 or 64; got $page_size" >&2
    exit 2
    ;;
esac
[[ "$fixed_patch_label" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe PATCH_LABEL: $fixed_patch_label" >&2
  exit 2
}
(( duration >= 900 )) || {
  echo "AgentX admission-ladder duration must be at least 900 seconds" >&2
  exit 2
}

declare -A seen=()
candidate_count=0
for maxrun in $candidate_maxruns; do
  [[ "$maxrun" =~ ^[1-9][0-9]*$ ]] || {
    echo "candidate max-running values must be positive integers: $maxrun" >&2
    exit 2
  }
  [[ "$maxrun" != "$control_maxrun" ]] || {
    echo "candidate list repeats control max-running value $control_maxrun" >&2
    exit 2
  }
  [[ -z "${seen[$maxrun]:-}" ]] || {
    echo "duplicate candidate max-running value: $maxrun" >&2
    exit 2
  }
  seen[$maxrun]=1
  ((candidate_count += 1))
done
(( candidate_count > 0 )) || {
  echo "candidate list is empty" >&2
  exit 2
}

for required in "$runner" "$point" "$evaluator" "$objective"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done
[[ "$point_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "POINT_SCRIPT_SHA256 must be a lowercase SHA256" >&2
  exit 2
}
actual_point_sha256="$(sha256sum "$point" | awk '{print $1}')"
[[ "$actual_point_sha256" == "$point_sha256" ]] || {
  echo "point launcher checksum mismatch: expected $point_sha256 got $actual_point_sha256" >&2
  exit 2
}
if [[ -n "$fixed_patch_path" ]]; then
  [[ -f "$fixed_patch_path" && "$fixed_patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "PATCH_PATH and a lowercase PATCH_SHA256 are required together" >&2
    exit 2
  }
  [[ -n "$expected_route_regex" ]] || {
    echo "EXPECTED_ROUTE_REGEX is required for a patched ladder" >&2
    exit 2
  }
  [[ "$(sha256sum "$fixed_patch_path" | awk '{print $1}')" == "$fixed_patch_sha256" ]]
else
  [[ -z "$fixed_patch_sha256" && -z "$expected_route_regex" \
    && -z "$expected_route_regex_2" && -z "$expected_route_regex_3" ]] || {
    echo "patch checksum and route regexes require PATCH_PATH" >&2
    exit 2
  }
fi
if [[ -n "$fixed_aiter_patch_path" ]]; then
  [[ -n "$fixed_patch_path" ]] || {
    echo "AITER_PATCH_PATH requires PATCH_PATH" >&2
    exit 2
  }
  [[ -f "$fixed_aiter_patch_path" && "$fixed_aiter_patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "AITER_PATCH_PATH and a lowercase AITER_PATCH_SHA256 are required together" >&2
    exit 2
  }
  [[ -n "$expected_route_regex_3" ]] || {
    echo "EXPECTED_ROUTE_REGEX_3 is required for an AITER-patched ladder" >&2
    exit 2
  }
  [[ "$(sha256sum "$fixed_aiter_patch_path" | awk '{print $1}')" == "$fixed_aiter_patch_sha256" ]]
elif [[ -n "$fixed_aiter_patch_sha256" ]]; then
  echo "AITER_PATCH_SHA256 was set without AITER_PATCH_PATH" >&2
  exit 2
fi
for manifest_path in $base_candidate_manifests; do
  [[ -f "$manifest_path" ]] || {
    echo "missing base candidate manifest: $manifest_path" >&2
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
  fuser /dev/kfd >/tmp/qwen35-pr2737-c12-ladder-kfd-users 2>/dev/null && dirty=1
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
  local label="$1"
  local maxrun="$2"
  local include_candidate="$3"
  local arm_tag result archive aggregate profile startup_count cancelled
  arm_tag="$(date +%Y%m%dT%H%M%S%z)"
  result="qwen35_pr2737_tp2ep1_c12_${fixed_patch_label}_maxrun${maxrun}_graph${graph_max_bs}_page${page_size}_recv${scheduler_recv_interval}_${label}_${duration}s_${arm_tag}"
  archive="$archive_root/$result"

  wait_clean
  printf '%s arm_start label=%s max_running_requests=%s graph_max_bs=%s result=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$maxrun" "$graph_max_bs" "$result"

  run_env=(
    TARGET_NODE="$target_node" \
    ARCHIVE_ROOT="$archive_root" \
    TRIGGER_JOB=99999999 \
    RESULT_NAME="$result" \
    DURATION="$duration" \
    CONC="$conc" \
    MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun" \
    CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs" \
    PAGE_SIZE_OVERRIDE="$page_size" \
    SCHEDULER_RECV_INTERVAL_OVERRIDE="$scheduler_recv_interval"
  )
  if [[ -n "$fixed_patch_path" ]]; then
    run_env+=(
      SGLANG_PATCH="$fixed_patch_path"
      SGLANG_PATCH_SHA256="$fixed_patch_sha256"
      SGLANG_GDN_DECODE_FUSION_LOG_LAYER_HITS=1
    )
  fi
  if [[ -n "$fixed_aiter_patch_path" ]]; then
    run_env+=(
      AITER_PATCH="$fixed_aiter_patch_path"
      AITER_PATCH_SHA256="$fixed_aiter_patch_sha256"
    )
  fi
  env "${run_env[@]}" bash "$runner" "$job_id" "$result" bash "$point" "$job_id"

  aggregate="$(find "$archive" -maxdepth 1 -type f -name '*.json' \
    ! -name power_validation.json \
    ! -name agentic_power_window.json \
    ! -name gpu_metrics_identity.json | head -1)"
  profile="$archive/aiperf_artifacts/profile_export_aiperf.json"
  [[ -f "$aggregate" && -f "$profile" && -f "$archive/SHA256SUMS.verify" ]]
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
  if ! jq -e '
      .metadata.submission_valid == true
      and (.error_summary | length == 0)
      and (.request_count.avg > 0)
    ' "$profile" >/dev/null; then
    echo "AIPerf profile validity check failed in $archive" >&2
    jq '{submission_valid: .metadata.submission_valid,
         submission_invalid_reasons: .metadata.submission_invalid_reasons,
         error_summary,
         request_count}' "$profile" >&2
    return 1
  fi

  grep -qx "max_running_requests=$maxrun" "$archive/run_identity.txt"
  grep -qx "cuda_graph_max_bs=$graph_max_bs" "$archive/run_identity.txt"
  grep -qx "page_size=$page_size" "$archive/run_identity.txt"
  grep -qx "scheduler_recv_interval=$scheduler_recv_interval" "$archive/run_identity.txt"
  grep -Eq -- "--max-running-requests[[:space:]]+${maxrun}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--cuda-graph-max-bs[[:space:]]+${graph_max_bs}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--page-size[[:space:]]+${page_size}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--scheduler-recv-interval[[:space:]]+${scheduler_recv_interval}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- '--max-prefill-tokens[[:space:]]+16384([[:space:]]|$)' "$archive/sglang_command.txt"
  grep -Eq -- '--chunked-prefill-size[[:space:]]+16384([[:space:]]|$)' "$archive/sglang_command.txt"
  grep -Eq -- "'mem_fraction_static': 0.68([,}])" "$archive/server.log"
  startup_count="$(grep -Ec 'Uvicorn running on' "$archive/server.log" || true)"
  [[ "$startup_count" == 1 ]]
  if [[ -n "$fixed_patch_path" ]]; then
    grep -qx "sglang_patch_sha256=$fixed_patch_sha256" "$archive/run_identity.txt"
    [[ -s "$archive/sglang_source.patch" && -s "$archive/sglang_worktree.patch" ]]
    grep -Eq "$expected_route_regex" "$archive/server.log"
    if [[ -n "$expected_route_regex_2" ]]; then
      grep -Eq "$expected_route_regex_2" "$archive/server.log"
    fi
    if [[ -n "$fixed_aiter_patch_path" ]]; then
      grep -qx "aiter_patch_sha256=$fixed_aiter_patch_sha256" "$archive/run_identity.txt"
      [[ -s "$archive/aiter_source.patch" && -s "$archive/aiter_worktree.patch" ]]
      grep -Eq "$expected_route_regex_3" "$archive/server.log"
    fi
  fi
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

  if [[ "$include_candidate" == 1 ]]; then
    jq -c \
      --arg name "${fixed_patch_label}-c12-maxrun${maxrun}-graph${graph_max_bs}-page${page_size}-${duration}s-screen" \
      --arg artifact "$archive" \
      --arg patch_sha256 "${fixed_patch_sha256:-none}" \
      --arg aiter_patch_sha256 "${fixed_aiter_patch_sha256:-none}" \
      --argjson maxrun "$maxrun" \
      --argjson page_size "$page_size" \
      --argjson scheduler_recv_interval "$scheduler_recv_interval" '
      {
        name: $name,
        status: "provisional",
        throughput_per_gpu_tokens_per_s: .request_metrics.throughput.per_gpu.total_tput_tps,
        p90_interactivity_tokens_per_s_user: .request_metrics.latency.full_response_intvty.p90,
        artifact: $artifact,
        metadata: {
          concurrency: 12,
          max_running_requests: $maxrun,
          page_size: $page_size,
          scheduler_recv_interval: $scheduler_recv_interval,
          sglang_patch_sha256: $patch_sha256,
          aiter_patch_sha256: $aiter_patch_sha256,
          duration_seconds: .request_metrics.throughput.duration_seconds,
          profiled_requests: .request_accounting.records_profiled,
          warmups: .request_accounting.records_warmup_dropped,
          errors: .request_accounting.records_error_dropped,
          power_valid: .power_valid
        }
      }
    ' "$aggregate" >>"$points_jsonl"
  fi
  printf '%s arm_done label=%s max_running_requests=%s archive=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$maxrun" "$archive"
}

: >"$points_jsonl"
printf 'label\tmax_running_requests\tthroughput_per_gpu\tp90_interactivity\tduration_seconds\tprofiled\twarmups\terrors\tavg_power_w\twas_cancelled\tarchive\n' >"$summary"
printf '%s campaign_start job_id=%s duration=%s control_maxrun=%s candidate_maxruns=%q graph_max_bs=%s page_size=%s scheduler_recv_interval=%s patch_label=%s summary=%s\n' \
  "$(date --iso-8601=seconds)" "$job_id" "$duration" "$control_maxrun" \
  "$candidate_maxruns" "$graph_max_bs" "$page_size" \
  "$scheduler_recv_interval" "$fixed_patch_label" "$summary"

run_arm control1 "$control_maxrun" 0
for maxrun in $candidate_maxruns; do
  run_arm "candidate_maxrun${maxrun}" "$maxrun" 1
done
run_arm control2 "$control_maxrun" 0
wait_clean

jq -s '{schema_version: 1, points: .}' "$points_jsonl" >"$manifest"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
eval_args+=(--candidates "$manifest" --include-provisional --json --output "$evaluation_json")
"${eval_args[@]}"

read -r control1_tput control1_p90 < <(
  awk -F '\t' '$1 == "control1" {print $3, $4}' "$summary"
)
read -r control2_tput control2_p90 < <(
  awk -F '\t' '$1 == "control2" {print $3, $4}' "$summary"
)
control_drift_ok="$(awk \
  -v t1="$control1_tput" -v i1="$control1_p90" \
  -v t2="$control2_tput" -v i2="$control2_p90" '
  BEGIN {
    tmean = (t1 + t2) / 2.0
    imean = (i1 + i2) / 2.0
    tdiff = (t1 > t2 ? t1 - t2 : t2 - t1) / tmean
    idiff = (i1 > i2 ? i1 - i2 : i2 - i1) / imean
    print (tdiff <= 0.10 && idiff <= 0.15) ? 1 : 0
  }')"
promotion_candidates="$(jq -r --slurpfile current "$manifest" '
  ($current[0].points | map(.name)) as $candidate_names
  | [.selected[]
     | select(.selected_status == "provisional")
     | .selected_point
     | select(. as $name | $candidate_names | index($name))]
  | unique | join(",")
' "$evaluation_json")"
provisional_mean="$(jq -r '.new_mean' "$evaluation_json")"
provisional_gain_pct="$(jq -r '.relative_mean_gain * 100' "$evaluation_json")"

{
  printf 'control1_throughput=%s\n' "$control1_tput"
  printf 'control1_p90_interactivity=%s\n' "$control1_p90"
  printf 'control2_throughput=%s\n' "$control2_tput"
  printf 'control2_p90_interactivity=%s\n' "$control2_p90"
  printf 'control_drift_ok=%s\n' "$control_drift_ok"
  printf 'provisional_frontier_mean=%s\n' "$provisional_mean"
  printf 'provisional_relative_mean_gain_pct=%s\n' "$provisional_gain_pct"
  printf 'promotion_candidates=%s\n' "$promotion_candidates"
  if [[ "$control_drift_ok" == 1 && -n "$promotion_candidates" ]]; then
    printf 'advance_selected_candidates_to_isolated_bracket=1\n'
  else
    printf 'advance_selected_candidates_to_isolated_bracket=0\n'
  fi
  printf 'summary=%s\nmanifest=%s\nevaluation=%s\n' \
    "$summary" "$manifest" "$evaluation_json"
} | tee "$decision"

printf '%s campaign_done summary=%s decision=%s\n' \
  "$(date --iso-8601=seconds)" "$summary" "$decision"
