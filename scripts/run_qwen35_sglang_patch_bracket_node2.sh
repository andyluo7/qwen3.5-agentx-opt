#!/usr/bin/env bash
#SBATCH --job-name=q35-sgl-patch-ab
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-sglang-patch-bracket-%j.out

# Compare one source patch against the exact frozen SGLang pin using a fresh
# control -> candidate -> control sequence. This is a qualification bracket;
# its candidate remains provisional until sustained confirmation and postflight.
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
patch_path="${PATCH_PATH:?PATCH_PATH is required}"
patch_sha256="${PATCH_SHA256:?PATCH_SHA256 is required}"
aiter_patch_path="${AITER_PATCH_PATH:-}"
aiter_patch_sha256="${AITER_PATCH_SHA256:-}"
patch_label="${PATCH_LABEL:?PATCH_LABEL is required}"
expected_route_regex="${EXPECTED_ROUTE_REGEX:?EXPECTED_ROUTE_REGEX is required}"
expected_route_regex_2="${EXPECTED_ROUTE_REGEX_2:-}"
expected_route_regex_3="${EXPECTED_ROUTE_REGEX_3:-}"
duration="${DURATION:-900}"
maxrun="${MAX_RUNNING_REQUESTS_OVERRIDE:-4}"
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
scheduler_recv_interval="${SCHEDULER_RECV_INTERVAL_OVERRIDE:-30}"
page_size="${PAGE_SIZE_OVERRIDE:-16}"
conc="${CONC:-12}"
case "$conc" in
  1) expected_warmups=11 ;;
  4) expected_warmups=43 ;;
  8) expected_warmups=87 ;;
  12) expected_warmups=131 ;;
  *)
    echo "source-patch bracket supports CONC=1, 4, 8, or 12; got $conc" >&2
    exit 2
    ;;
esac
run_tag="$(date +%Y%m%dT%H%M%S%z)"
prefix="$shared_root/qwen35-pr2737-c${conc}-${patch_label}-maxrun${maxrun}-${duration}s-aba-${run_tag}"
summary="$prefix.tsv"
manifest="$prefix.candidates.json"
evaluation_json="$prefix.evaluation.json"
decision="$prefix.decision.txt"

[[ "${SLURM_GPUS_ON_NODE:-}" == 2 ]] || {
  echo "expected exactly two allocated GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
[[ "$patch_label" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe PATCH_LABEL: $patch_label" >&2
  exit 2
}
[[ "$patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "PATCH_SHA256 must be a lowercase SHA256" >&2
  exit 2
}
for value in \
  "$duration" "$maxrun" "$graph_max_bs" \
  "$scheduler_recv_interval" "$page_size"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "duration, max-running, graph size, scheduler interval, and page size must be positive integers" >&2
    exit 2
  }
done
case "$page_size" in
  16|64) ;;
  *)
    echo "source-patch bracket supports PAGE_SIZE_OVERRIDE=16 or 64; got $page_size" >&2
    exit 2
    ;;
esac
(( duration >= 900 )) || {
  echo "AgentX qualification duration must be at least 900 seconds" >&2
  exit 2
}
for required in "$runner" "$point" "$evaluator" "$objective" "$patch_path"; do
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
actual_patch_sha256="$(sha256sum "$patch_path" | awk '{print $1}')"
[[ "$actual_patch_sha256" == "$patch_sha256" ]] || {
  echo "patch checksum mismatch: expected $patch_sha256 got $actual_patch_sha256" >&2
  exit 2
}
if [[ -n "$aiter_patch_path" ]]; then
  [[ -f "$aiter_patch_path" ]] || {
    echo "missing AITER patch: $aiter_patch_path" >&2
    exit 1
  }
  [[ "$aiter_patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "AITER_PATCH_SHA256 must be a lowercase SHA256" >&2
    exit 2
  }
  actual_aiter_patch_sha256="$(sha256sum "$aiter_patch_path" | awk '{print $1}')"
  [[ "$actual_aiter_patch_sha256" == "$aiter_patch_sha256" ]] || {
    echo "AITER patch checksum mismatch: expected $aiter_patch_sha256 got $actual_aiter_patch_sha256" >&2
    exit 2
  }
elif [[ -n "$aiter_patch_sha256" ]]; then
  echo "AITER_PATCH_SHA256 was set without AITER_PATCH_PATH" >&2
  exit 2
fi

wait_clean() {
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --nodelist="$target_node" bash -s <<'PREFLIGHT'
set -euo pipefail
for attempt in $(seq 1 60); do
  dirty=0
  ss -ltn 2>/dev/null | grep -q ':8888 ' && dirty=1
  fuser /dev/kfd >/tmp/qwen35-sglang-patch-bracket-kfd-users 2>/dev/null && dirty=1
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
  local patched="$2"
  local arm_tag result archive aggregate profile startup_count cancelled
  arm_tag="$(date +%Y%m%dT%H%M%S%z)"
  result="qwen35_pr2737_tp2ep1_c${conc}_${patch_label}_maxrun${maxrun}_${label}_${duration}s_${arm_tag}"
  archive="$archive_root/$result"

  wait_clean
  printf '%s arm_start label=%s patched=%s max_running_requests=%s result=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$patched" "$maxrun" "$result"

  if [[ "$patched" == 1 ]]; then
    env \
      TARGET_NODE="$target_node" \
      ARCHIVE_ROOT="$archive_root" \
      TRIGGER_JOB=99999999 \
      RESULT_NAME="$result" \
      DURATION="$duration" \
      CONC="$conc" \
      MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun" \
      CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs" \
      SCHEDULER_RECV_INTERVAL_OVERRIDE="$scheduler_recv_interval" \
      PAGE_SIZE_OVERRIDE="$page_size" \
      SGLANG_PATCH="$patch_path" \
      SGLANG_PATCH_SHA256="$patch_sha256" \
      AITER_PATCH="$aiter_patch_path" \
      AITER_PATCH_SHA256="$aiter_patch_sha256" \
      SGLANG_GDN_DECODE_FUSION_LOG_LAYER_HITS=1 \
      bash "$runner" "$job_id" "$result" bash "$point" "$job_id"
  else
    env \
      -u SGLANG_PATCH \
      -u SGLANG_PATCH_SHA256 \
      -u AITER_PATCH \
      -u AITER_PATCH_SHA256 \
      TARGET_NODE="$target_node" \
      ARCHIVE_ROOT="$archive_root" \
      TRIGGER_JOB=99999999 \
      RESULT_NAME="$result" \
      DURATION="$duration" \
      CONC="$conc" \
      MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun" \
      CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs" \
      SCHEDULER_RECV_INTERVAL_OVERRIDE="$scheduler_recv_interval" \
      PAGE_SIZE_OVERRIDE="$page_size" \
      SGLANG_GDN_DECODE_FUSION_LOG_LAYER_HITS=1 \
      bash "$runner" "$job_id" "$result" bash "$point" "$job_id"
  fi

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
  grep -qx "scheduler_recv_interval=$scheduler_recv_interval" "$archive/run_identity.txt"
  grep -qx "page_size=$page_size" "$archive/run_identity.txt"
  grep -Eq -- "--max-running-requests[[:space:]]+${maxrun}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--cuda-graph-max-bs[[:space:]]+${graph_max_bs}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--scheduler-recv-interval[[:space:]]+${scheduler_recv_interval}([[:space:]]|$)" "$archive/sglang_command.txt"
  grep -Eq -- "--page-size[[:space:]]+${page_size}([[:space:]]|$)" "$archive/sglang_command.txt"
  startup_count="$(grep -Ec 'Uvicorn running on' "$archive/server.log" || true)"
  [[ "$startup_count" == 1 ]]
  if grep -REiq \
    'HIP error|illegal memory access|device-side assert|HSA_STATUS_ERROR_EXCEPTION|EngineDeadError|GPU fault|page fault' \
    "$archive/server.log" "$archive/benchmark.log" "$archive/driver.log" \
    "$archive/aiperf_artifacts/logs/aiperf.log"; then
    echo "fatal runtime signature found in $archive" >&2
    return 1
  fi

  if [[ "$patched" == 1 ]]; then
    grep -qx "sglang_patch_sha256=$patch_sha256" "$archive/run_identity.txt"
    [[ -s "$archive/sglang_source.patch" && -s "$archive/sglang_worktree.patch" ]]
    if [[ -n "$aiter_patch_path" ]]; then
      grep -qx "aiter_patch_sha256=$aiter_patch_sha256" "$archive/run_identity.txt"
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
    if grep -Eq "$expected_route_regex" "$archive/server.log"; then
      echo "candidate route unexpectedly engaged in control $archive" >&2
      return 1
    fi
    if [[ -n "$expected_route_regex_2" ]] \
      && grep -Eq "$expected_route_regex_2" "$archive/server.log"; then
      echo "second candidate route unexpectedly engaged in control $archive" >&2
      return 1
    fi
    if [[ -n "$expected_route_regex_3" ]] \
      && grep -Eq "$expected_route_regex_3" "$archive/server.log"; then
      echo "third candidate route unexpectedly engaged in control $archive" >&2
      return 1
    fi
  fi

  wait_clean
  validate_teardown "$archive/teardown.txt"
  cancelled="$(jq -r '.was_cancelled' "$profile")"
  jq -r \
    --arg label "$label" \
    --arg archive "$archive" \
    --arg cancelled "$cancelled" \
    --argjson patched "$patched" '
      [$label,
       ($patched | tostring),
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

  if [[ "$patched" == 1 ]]; then
    jq -n \
      --arg name "${patch_label}-c${conc}-maxrun${maxrun}-${duration}s-screen" \
      --arg artifact "$archive" \
      --argjson throughput "$(jq -r '.request_metrics.throughput.per_gpu.total_tput_tps' "$aggregate")" \
      --argjson p90 "$(jq -r '.request_metrics.latency.full_response_intvty.p90' "$aggregate")" \
      --argjson conc "$conc" \
      --argjson maxrun "$maxrun" \
      --argjson graph_max_bs "$graph_max_bs" \
      --argjson scheduler_recv_interval "$scheduler_recv_interval" \
      --argjson page_size "$page_size" \
      --arg patch_sha256 "$patch_sha256" \
      --arg aiter_patch_sha256 "$aiter_patch_sha256" \
      '{
        schema_version: 1,
        points: [{
          name: $name,
          status: "provisional",
          throughput_per_gpu_tokens_per_s: $throughput,
          p90_interactivity_tokens_per_s_user: $p90,
          artifact: $artifact,
          metadata: {
            concurrency: $conc,
            max_running_requests: $maxrun,
            cuda_graph_max_bs: $graph_max_bs,
            scheduler_recv_interval: $scheduler_recv_interval,
            page_size: $page_size,
            sglang_patch_sha256: $patch_sha256,
            aiter_patch_sha256: ($aiter_patch_sha256 | select(length > 0) // "none")
          }
        }]
      }' >"$manifest"
  fi
  printf '%s arm_done label=%s patched=%s archive=%s\n' \
    "$(date --iso-8601=seconds)" "$label" "$patched" "$archive"
}

printf 'label\tpatched\tthroughput_per_gpu\tp90_interactivity\tduration_seconds\tprofiled\twarmups\terrors\tavg_power_w\twas_cancelled\tarchive\n' >"$summary"
printf '%s campaign_start job_id=%s patch_label=%s patch_sha256=%s aiter_patch_sha256=%s duration=%s maxrun=%s graph_max_bs=%s summary=%s\n' \
  "$(date --iso-8601=seconds)" "$job_id" "$patch_label" "$patch_sha256" \
  "${aiter_patch_sha256:-none}" "$duration" "$maxrun" "$graph_max_bs" "$summary"

run_arm control1 0
run_arm candidate 1
run_arm control2 0
wait_clean

eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
eval_args+=(--candidates "$manifest" --include-provisional --json --output "$evaluation_json")
"${eval_args[@]}"

read -r control1_tput control1_p90 < <(
  awk -F '\t' '$1 == "control1" {print $3, $4}' "$summary"
)
read -r candidate_tput candidate_p90 < <(
  awk -F '\t' '$1 == "candidate" {print $3, $4}' "$summary"
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
beats_both_controls_p90="$(awk \
  -v c1="$control1_p90" -v candidate="$candidate_p90" -v c2="$control2_p90" \
  'BEGIN {print (candidate > c1 && candidate > c2) ? 1 : 0}')"
candidate_name="$(jq -r '.points[0].name' "$manifest")"
selected_anchor_count="$(jq --arg name "$candidate_name" \
  '[.selected[] | select(.selected_point == $name)] | length' "$evaluation_json")"
provisional_mean="$(jq -r '.new_mean' "$evaluation_json")"
provisional_gain_pct="$(jq -r '.relative_mean_gain * 100' "$evaluation_json")"

{
  printf 'control1_throughput=%s\ncontrol1_p90_interactivity=%s\n' \
    "$control1_tput" "$control1_p90"
  printf 'candidate_throughput=%s\ncandidate_p90_interactivity=%s\n' \
    "$candidate_tput" "$candidate_p90"
  printf 'control2_throughput=%s\ncontrol2_p90_interactivity=%s\n' \
    "$control2_tput" "$control2_p90"
  printf 'control_drift_ok=%s\n' "$control_drift_ok"
  printf 'candidate_beats_both_controls_p90=%s\n' "$beats_both_controls_p90"
  printf 'selected_anchor_count=%s\n' "$selected_anchor_count"
  printf 'provisional_frontier_mean=%s\n' "$provisional_mean"
  printf 'provisional_relative_mean_gain_pct=%s\n' "$provisional_gain_pct"
  if [[ "$control_drift_ok" == 1 && "$beats_both_controls_p90" == 1 && "$selected_anchor_count" -gt 0 ]]; then
    printf 'advance_to_sustained_confirmation=1\n'
  else
    printf 'advance_to_sustained_confirmation=0\n'
  fi
  printf 'summary=%s\nmanifest=%s\nevaluation=%s\n' \
    "$summary" "$manifest" "$evaluation_json"
} | tee "$decision"

printf '%s campaign_done summary=%s decision=%s\n' \
  "$(date --iso-8601=seconds)" "$summary" "$decision"
