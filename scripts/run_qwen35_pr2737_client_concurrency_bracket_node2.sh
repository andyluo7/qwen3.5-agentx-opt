#!/usr/bin/env bash
#SBATCH --job-name=q35-client-conc-ab
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=05:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-client-concurrency-bracket-%j.out

# Test a lower client-concurrency load against a repeated C12 endpoint while
# keeping the server admission cap fixed. This directly tests whether queueing
# at C12 is depressing full-response interactivity at otherwise equal serving
# throughput.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
archive_root="${ARCHIVE_ROOT:-/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
runner="$shared_root/run_and_archive_node2.sh"
point="${POINT_SCRIPT:-$shared_root/run_qwen35_pr2737_c12_exact_point_node2.sh}"
point_sha256="${POINT_SCRIPT_SHA256:-cb6f1e1526c46176d0326e2a9f05ecfae73a40cf4209f6bbad890eb3a9561bb8}"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:-}"
duration="${DURATION:-900}"
control_conc="${CONTROL_CONC:-12}"
candidate_concs="${CANDIDATE_CONCS:-4}"
maxrun="${MAX_RUNNING_REQUESTS_OVERRIDE:-1}"
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
control_page_size="${CONTROL_PAGE_SIZE:-16}"
candidate_page_size="${CANDIDATE_PAGE_SIZE:-$control_page_size}"
control_scheduler_recv_interval="${CONTROL_SCHEDULER_RECV_INTERVAL:-30}"
candidate_scheduler_recv_interval="${CANDIDATE_SCHEDULER_RECV_INTERVAL:-$control_scheduler_recv_interval}"
fixed_patch_path="${PATCH_PATH:-}"
fixed_patch_sha256="${PATCH_SHA256:-}"
fixed_aiter_patch_path="${AITER_PATCH_PATH:-}"
fixed_aiter_patch_sha256="${AITER_PATCH_SHA256:-}"
fixed_patch_label="${PATCH_LABEL:-exact}"
expected_route_regex="${EXPECTED_ROUTE_REGEX:-}"
expected_route_regex_2="${EXPECTED_ROUTE_REGEX_2:-}"
expected_route_regex_3="${EXPECTED_ROUTE_REGEX_3:-}"
require_candidate_p90_above_controls="${REQUIRE_CANDIDATE_P90_ABOVE_CONTROLS:-1}"
run_tag="$(date +%Y%m%dT%H%M%S%z)"
prefix="$shared_root/qwen35-pr2737-client-concurrency-maxrun${maxrun}-${duration}s-${run_tag}"
summary="$prefix.tsv"
points_jsonl="$prefix.points.jsonl"
manifest="$prefix.candidates.json"
evaluation_json="$prefix.evaluation.json"
decision="$prefix.decision.txt"

supported_concurrency() {
  case "$1" in
    1|4|6|7|8|12) ;;
    *) return 1 ;;
  esac
}

expected_warmups_from_log() {
  local log="$1"
  local conc="$2"
  local line per_lane primers
  local -a warmup_lines=()
  mapfile -t warmup_lines < <(
    grep -E 'WARMUP count budget: [0-9]+ additional requests per lane after [0-9]+ mandatory snapshot primers' "$log"
  )
  (( ${#warmup_lines[@]} == 1 )) || {
    echo "expected exactly one AIPerf warmup budget line in $log; found ${#warmup_lines[@]}" >&2
    return 1
  }
  line="${warmup_lines[0]}"
  read -r per_lane primers < <(
    sed -E 's/.*WARMUP count budget: ([0-9]+) additional requests per lane after ([0-9]+) mandatory snapshot primers.*/\1 \2/' <<<"$line"
  )
  [[ "$per_lane" == 10 && "$primers" =~ ^[0-9]+$ ]] || {
    echo "unexpected AIPerf warmup budget line: $line" >&2
    return 1
  }
  printf '%s\n' "$((per_lane * conc + primers))"
}

[[ "${SLURM_GPUS_ON_NODE:-}" == 2 ]] || {
  echo "expected exactly two allocated GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
for value in \
  "$duration" "$control_conc" "$maxrun" "$graph_max_bs" \
  "$control_page_size" "$candidate_page_size" \
  "$control_scheduler_recv_interval" "$candidate_scheduler_recv_interval"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "duration, concurrency, max-running, graph size, page size, and scheduler interval must be positive integers" >&2
    exit 2
  }
done
for page_size in "$control_page_size" "$candidate_page_size"; do
  case "$page_size" in
    16|64) ;;
    *)
      echo "page sizes must be 16 or 64; got $page_size" >&2
      exit 2
      ;;
  esac
done
[[ "$require_candidate_p90_above_controls" == 0 \
  || "$require_candidate_p90_above_controls" == 1 ]] || {
  echo "REQUIRE_CANDIDATE_P90_ABOVE_CONTROLS must be 0 or 1" >&2
  exit 2
}
(( duration >= 900 )) || {
  echo "AgentX client-concurrency bracket duration must be at least 900 seconds" >&2
  exit 2
}
supported_concurrency "$control_conc" || {
  echo "unsupported control concurrency: $control_conc" >&2
  exit 2
}

declare -A seen=()
candidate_count=0
for conc in $candidate_concs; do
  [[ "$conc" =~ ^[1-9][0-9]*$ ]] || {
    echo "candidate concurrency must be a positive integer: $conc" >&2
    exit 2
  }
  supported_concurrency "$conc" || {
    echo "unsupported candidate concurrency: $conc" >&2
    exit 2
  }
  if [[ "$conc" == "$control_conc" \
    && "$candidate_page_size" == "$control_page_size" \
    && "$candidate_scheduler_recv_interval" == "$control_scheduler_recv_interval" ]]; then
    echo "candidate repeats the control concurrency, page size, and scheduler interval" >&2
    exit 2
  fi
  [[ -z "${seen[$conc]:-}" ]] || {
    echo "duplicate candidate concurrency: $conc" >&2
    exit 2
  }
  seen[$conc]=1
  ((candidate_count += 1))
done

[[ "$fixed_patch_label" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe PATCH_LABEL: $fixed_patch_label" >&2
  exit 2
}
if [[ -n "$fixed_patch_path" ]]; then
  [[ -f "$fixed_patch_path" ]] || {
    echo "PATCH_PATH does not exist: $fixed_patch_path" >&2
    exit 2
  }
  [[ "$fixed_patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "PATCH_SHA256 must be a lowercase SHA256" >&2
    exit 2
  }
  [[ -n "$expected_route_regex" ]] || {
    echo "EXPECTED_ROUTE_REGEX is required for a patched bracket" >&2
    exit 2
  }
  actual_patch_sha256="$(sha256sum "$fixed_patch_path" | awk '{print $1}')"
  [[ "$actual_patch_sha256" == "$fixed_patch_sha256" ]] || {
    echo "patch checksum mismatch: expected $fixed_patch_sha256 got $actual_patch_sha256" >&2
    exit 2
  }
else
  [[ -z "$fixed_patch_sha256" && -z "$expected_route_regex" \
    && -z "$expected_route_regex_2" && -z "$expected_route_regex_3" ]] || {
    echo "PATCH_SHA256 and route regexes require PATCH_PATH" >&2
    exit 2
  }
fi
if [[ -n "$fixed_aiter_patch_path" ]]; then
  [[ -n "$fixed_patch_path" ]] || {
    echo "AITER_PATCH_PATH requires PATCH_PATH" >&2
    exit 2
  }
  [[ -f "$fixed_aiter_patch_path" ]] || {
    echo "AITER_PATCH_PATH does not exist: $fixed_aiter_patch_path" >&2
    exit 2
  }
  [[ "$fixed_aiter_patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "AITER_PATCH_SHA256 must be a lowercase SHA256" >&2
    exit 2
  }
  [[ -n "$expected_route_regex_3" ]] || {
    echo "EXPECTED_ROUTE_REGEX_3 is required for an AITER-patched bracket" >&2
    exit 2
  }
  actual_aiter_patch_sha256="$(sha256sum "$fixed_aiter_patch_path" | awk '{print $1}')"
  [[ "$actual_aiter_patch_sha256" == "$fixed_aiter_patch_sha256" ]] || {
    echo "AITER patch checksum mismatch: expected $fixed_aiter_patch_sha256 got $actual_aiter_patch_sha256" >&2
    exit 2
  }
elif [[ -n "$fixed_aiter_patch_sha256" ]]; then
  echo "AITER_PATCH_SHA256 was set without AITER_PATCH_PATH" >&2
  exit 2
fi
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
  echo "point launcher checksum mismatch: expected $point_sha256 got $actual_point_sha256 for $point" >&2
  exit 2
}
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
  fuser /dev/kfd >/tmp/qwen35-client-concurrency-kfd-users 2>/dev/null && dirty=1
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
  local conc="$2"
  local include_candidate="$3"
  local page_size="$4"
  local scheduler_recv_interval="$5"
  local expected_warmups arm_tag result archive aggregate profile startup_count cancelled candidate_name
  arm_tag="$(date +%Y%m%dT%H%M%S%z)"
  result="qwen35_pr2737_tp2ep1_c${conc}_${fixed_patch_label}_maxrun${maxrun}_graph${graph_max_bs}_page${page_size}_recv${scheduler_recv_interval}_${label}_${duration}s_${arm_tag}"
  archive="$archive_root/$result"

  wait_clean
  printf '%s arm_start label=%s concurrency=%s max_running_requests=%s page_size=%s scheduler_recv_interval=%s patch_label=%s result=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$conc" "$maxrun" "$page_size" \
    "$scheduler_recv_interval" "$fixed_patch_label" "$result"

  run_env=(
    TARGET_NODE="$target_node"
    ARCHIVE_ROOT="$archive_root"
    TRIGGER_JOB=99999999
    RESULT_NAME="$result"
    DURATION="$duration"
    CONC="$conc"
    MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun"
    CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs"
    PAGE_SIZE_OVERRIDE="$page_size"
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
  expected_warmups="$(expected_warmups_from_log \
    "$archive/aiperf_artifacts/logs/aiperf.log" "$conc")"
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
  grep -qx "concurrency=$conc" "$archive/run_identity.txt"
  grep -qx "page_size=$page_size" "$archive/run_identity.txt"
  grep -qx "scheduler_recv_interval=$scheduler_recv_interval" "$archive/run_identity.txt"
  grep -Eq -- "--max-running-requests[[:space:]]+${maxrun}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--cuda-graph-max-bs[[:space:]]+${graph_max_bs}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--page-size[[:space:]]+${page_size}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--scheduler-recv-interval[[:space:]]+${scheduler_recv_interval}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "'mem_fraction_static': 0.68([,}])" "$archive/server.log"
  if [[ -n "$fixed_patch_path" ]]; then
    grep -qx "sglang_patch_sha256=$fixed_patch_sha256" "$archive/run_identity.txt"
    [[ -s "$archive/sglang_source.patch" && -s "$archive/sglang_worktree.patch" ]]
    if [[ -n "$fixed_aiter_patch_path" ]]; then
      grep -qx "aiter_patch_sha256=$fixed_aiter_patch_sha256" "$archive/run_identity.txt"
      [[ -s "$archive/aiter_source.patch" && -s "$archive/aiter_worktree.patch" ]]
    else
      grep -qx 'aiter_patch_sha256=none' "$archive/run_identity.txt"
      [[ ! -e "$archive/aiter_source.patch" && ! -e "$archive/aiter_worktree.patch" ]]
    fi
    grep -Eq "$expected_route_regex" "$archive/server.log"
    if [[ -n "$expected_route_regex_2" ]]; then
      grep -Eq "$expected_route_regex_2" "$archive/server.log"
    fi
    if [[ -n "$expected_route_regex_3" ]]; then
      grep -Eq "$expected_route_regex_3" "$archive/server.log"
    fi
  else
    grep -qx 'sglang_patch_sha256=none' "$archive/run_identity.txt"
    grep -qx 'aiter_patch_sha256=none' "$archive/run_identity.txt"
    [[ ! -e "$archive/sglang_source.patch" && ! -e "$archive/sglang_worktree.patch" ]]
    [[ ! -e "$archive/aiter_source.patch" && ! -e "$archive/aiter_worktree.patch" ]]
  fi
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
    --argjson conc "$conc" \
    --argjson maxrun "$maxrun" \
    --argjson scheduler_recv_interval "$scheduler_recv_interval" '
      [$label,
       ($conc | tostring),
       ($maxrun | tostring),
       (.request_metrics.throughput.per_gpu.total_tput_tps | tostring),
       (.request_metrics.latency.full_response_intvty.p90 | tostring),
       (.request_metrics.throughput.duration_seconds | tostring),
       (.request_accounting.records_profiled | tostring),
       (.request_accounting.records_warmup_dropped | tostring),
       (.request_accounting.records_error_dropped | tostring),
       (.avg_power_w | tostring),
       ($cancelled | tostring),
       $archive,
       ($scheduler_recv_interval | tostring)] | @tsv
    ' "$aggregate" | tee -a "$summary"

  if [[ "$include_candidate" == 1 ]]; then
    candidate_name="exact-pr2737-c${conc}-maxrun${maxrun}-graph${graph_max_bs}-${duration}s-screen"
    if [[ "$page_size" != 16 ]]; then
      candidate_name="exact-pr2737-c${conc}-maxrun${maxrun}-graph${graph_max_bs}-page${page_size}-${duration}s-screen"
    fi
    if [[ "$scheduler_recv_interval" != 30 ]]; then
      candidate_name="${fixed_patch_label}-c${conc}-maxrun${maxrun}-graph${graph_max_bs}-page${page_size}-recv${scheduler_recv_interval}-${duration}s-screen"
    elif [[ -n "$fixed_patch_path" ]]; then
      candidate_name="${fixed_patch_label}-c${conc}-maxrun${maxrun}-graph${graph_max_bs}-page${page_size}-${duration}s-screen"
    fi
    jq -c \
      --arg name "$candidate_name" \
      --arg artifact "$archive" \
      --argjson conc "$conc" \
      --argjson maxrun "$maxrun" \
      --argjson page_size "$page_size" \
      --argjson scheduler_recv_interval "$scheduler_recv_interval" \
      --arg patch_sha256 "${fixed_patch_sha256:-none}" \
      --arg aiter_patch_sha256 "${fixed_aiter_patch_sha256:-none}" '
      {
        name: $name,
        status: "provisional",
        throughput_per_gpu_tokens_per_s: .request_metrics.throughput.per_gpu.total_tput_tps,
        p90_interactivity_tokens_per_s_user: .request_metrics.latency.full_response_intvty.p90,
        artifact: $artifact,
        metadata: {
          concurrency: $conc,
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
  printf '%s arm_done label=%s concurrency=%s page_size=%s scheduler_recv_interval=%s patch_label=%s archive=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$conc" "$page_size" \
    "$scheduler_recv_interval" "$fixed_patch_label" "$archive"
}

: >"$points_jsonl"
printf 'label\tconcurrency\tmax_running_requests\tthroughput_per_gpu\tp90_interactivity\tduration_seconds\tprofiled\twarmups\terrors\tavg_power_w\twas_cancelled\tarchive\tscheduler_recv_interval\n' >"$summary"
printf '%s campaign_start job_id=%s duration=%s control_concurrency=%s candidate_concurrencies=%q maxrun=%s graph_max_bs=%s control_page_size=%s candidate_page_size=%s control_scheduler_recv_interval=%s candidate_scheduler_recv_interval=%s patch_label=%s require_candidate_p90_above_controls=%s summary=%s\n' \
  "$(date --iso-8601=seconds)" "$job_id" "$duration" "$control_conc" \
  "$candidate_concs" "$maxrun" "$graph_max_bs" "$control_page_size" \
  "$candidate_page_size" "$control_scheduler_recv_interval" \
  "$candidate_scheduler_recv_interval" "$fixed_patch_label" \
  "$require_candidate_p90_above_controls" "$summary"

run_arm control1 "$control_conc" 0 "$control_page_size" "$control_scheduler_recv_interval"
for conc in $candidate_concs; do
  run_arm "candidate_c${conc}" "$conc" 1 "$candidate_page_size" "$candidate_scheduler_recv_interval"
done
run_arm control2 "$control_conc" 0 "$control_page_size" "$control_scheduler_recv_interval"
wait_clean

jq -s '{schema_version: 1, points: .}' "$points_jsonl" >"$manifest"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
eval_args+=(--candidates "$manifest" --include-provisional --json --output "$evaluation_json")
"${eval_args[@]}"

read -r control1_tput control1_p90 < <(
  awk -F '\t' '$1 == "control1" {print $4, $5}' "$summary"
)
read -r control2_tput control2_p90 < <(
  awk -F '\t' '$1 == "control2" {print $4, $5}' "$summary"
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
selected_candidate_names="$(jq -r --slurpfile current "$manifest" '
  ($current[0].points | map(.name)) as $candidate_names
  | [.selected[]
     | select(.selected_status == "provisional")
     | .selected_point
     | select(. as $name | $candidate_names | index($name))]
  | unique | join(",")
' "$evaluation_json")"
promotion_candidates=""
while IFS= read -r candidate_name; do
  [[ -n "$candidate_name" ]] || continue
  candidate_p90="$(jq -r --arg name "$candidate_name" \
    '.points[] | select(.name == $name) | .p90_interactivity_tokens_per_s_user' \
    "$manifest")"
  candidate_p90_control_gate=0
  if [[ "$require_candidate_p90_above_controls" == 0 ]] \
    || awk -v c1="$control1_p90" -v candidate="$candidate_p90" -v c2="$control2_p90" \
      'BEGIN {exit !(candidate > c1 && candidate > c2)}'; then
    candidate_p90_control_gate=1
  fi
  if [[ "$candidate_p90_control_gate" == 1 ]]; then
    if [[ -n "$promotion_candidates" ]]; then
      promotion_candidates+=","
    fi
    promotion_candidates+="$candidate_name"
  fi
done < <(tr ',' '\n' <<<"$selected_candidate_names")
provisional_mean="$(jq -r '.new_mean' "$evaluation_json")"
provisional_gain_pct="$(jq -r '.relative_mean_gain * 100' "$evaluation_json")"
remaining_mean_gain="$(jq -r '.remaining_mean_gain' "$evaluation_json")"

{
  printf 'control1_throughput=%s\ncontrol1_p90_interactivity=%s\n' \
    "$control1_tput" "$control1_p90"
  printf 'control2_throughput=%s\ncontrol2_p90_interactivity=%s\n' \
    "$control2_tput" "$control2_p90"
  printf 'control_drift_ok=%s\n' "$control_drift_ok"
  printf 'require_candidate_p90_above_controls=%s\n' \
    "$require_candidate_p90_above_controls"
  printf 'provisional_frontier_mean=%s\n' "$provisional_mean"
  printf 'provisional_relative_mean_gain_pct=%s\n' "$provisional_gain_pct"
  printf 'remaining_mean_gain=%s\n' "$remaining_mean_gain"
  printf 'promotion_candidates=%s\n' "$promotion_candidates"
  if [[ "$control_drift_ok" == 1 && -n "$promotion_candidates" ]]; then
    printf 'advance_selected_candidates_to_sustained_confirmation=1\n'
  else
    printf 'advance_selected_candidates_to_sustained_confirmation=0\n'
  fi
  printf 'summary=%s\nmanifest=%s\nevaluation=%s\n' \
    "$summary" "$manifest" "$evaluation_json"
} | tee "$decision"

printf '%s campaign_done summary=%s decision=%s\n' \
  "$(date --iso-8601=seconds)" "$summary" "$decision"
