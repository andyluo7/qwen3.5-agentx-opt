#!/usr/bin/env bash
#SBATCH --job-name=q35-frontier-confirm
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-frontier-confirm-%j.out

# Sustain one qualification-screen winner for at least 3,600 seconds. The
# result remains provisional until the independent full-node postflight emits
# an accepted manifest.
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

qualification_manifest="${QUALIFICATION_MANIFEST:?QUALIFICATION_MANIFEST is required}"
qualification_decision="${QUALIFICATION_DECISION:?QUALIFICATION_DECISION is required}"
qualification_name="${QUALIFICATION_NAME:?QUALIFICATION_NAME is required}"
qualification_gate="${QUALIFICATION_GATE:-advance_to_sustained_confirmation=1}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:-}"

result_label="${RESULT_LABEL:?RESULT_LABEL is required}"
duration="${DURATION:-3600}"
conc="${CONC:-12}"
maxrun="${MAX_RUNNING_REQUESTS_OVERRIDE:?MAX_RUNNING_REQUESTS_OVERRIDE is required}"
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
scheduler_recv_interval="${SCHEDULER_RECV_INTERVAL_OVERRIDE:-30}"
page_size="${PAGE_SIZE_OVERRIDE:-16}"
patch_path="${PATCH_PATH:-}"
patch_sha256="${PATCH_SHA256:-}"
aiter_patch_path="${AITER_PATCH_PATH:-}"
aiter_patch_sha256="${AITER_PATCH_SHA256:-}"
expected_route_regex="${EXPECTED_ROUTE_REGEX:-}"
expected_route_regex_2="${EXPECTED_ROUTE_REGEX_2:-}"
expected_route_regex_3="${EXPECTED_ROUTE_REGEX_3:-}"

case "$conc" in
  1|4|6|7|8|12) ;;
  *)
    echo "frontier confirmation supports CONC=1, 4, 6, 7, 8, or 12; got $conc" >&2
    exit 2
    ;;
esac

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
[[ "$result_label" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe RESULT_LABEL: $result_label" >&2
  exit 2
}
[[ "$qualification_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe QUALIFICATION_NAME: $qualification_name" >&2
  exit 2
}
[[ "$qualification_gate" =~ ^[A-Za-z0-9_]+=[01]$ ]] || {
  echo "QUALIFICATION_GATE must be an exact key=0/1 line" >&2
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
    echo "frontier confirmation supports PAGE_SIZE_OVERRIDE=16 or 64; got $page_size" >&2
    exit 2
    ;;
esac
(( duration >= 3600 )) || {
  echo "sustained confirmation duration must be at least 3600 seconds" >&2
  exit 2
}

for required in \
  "$runner" "$point" "$evaluator" "$objective" \
  "$qualification_manifest" "$qualification_decision"; do
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
grep -Fqx "$qualification_gate" "$qualification_decision" || {
  echo "qualification decision does not contain: $qualification_gate" >&2
  exit 3
}
grep -Fqx "manifest=$qualification_manifest" "$qualification_decision" || {
  echo "qualification decision is not bound to $qualification_manifest" >&2
  exit 3
}
[[ "$(jq -r '.points | length' "$qualification_manifest")" == 1 ]]
[[ "$(jq -r '.points[0].name' "$qualification_manifest")" == "$qualification_name" ]]
[[ "$(jq -r '.points[0].status' "$qualification_manifest")" == provisional ]]
jq -e '.points[0].throughput_per_gpu_tokens_per_s > 0' \
  "$qualification_manifest" >/dev/null
jq -e '.points[0].p90_interactivity_tokens_per_s_user > 0' \
  "$qualification_manifest" >/dev/null
manifest_conc="$(jq -r '.points[0].metadata.concurrency // empty' "$qualification_manifest")"
[[ -z "$manifest_conc" || "$manifest_conc" == "$conc" ]]
if [[ -n "$patch_sha256" ]]; then
  [[ "$(jq -r '.points[0].metadata.sglang_patch_sha256 // empty' "$qualification_manifest")" == "$patch_sha256" ]]
fi
if [[ -n "$aiter_patch_sha256" ]]; then
  [[ "$(jq -r '.points[0].metadata.aiter_patch_sha256 // empty' "$qualification_manifest")" == "$aiter_patch_sha256" ]]
fi
qualification_artifact="$(jq -r '.points[0].artifact' "$qualification_manifest")"
[[ -d "$qualification_artifact" ]] || {
  echo "qualification artifact is not a directory: $qualification_artifact" >&2
  exit 3
}
grep -qx "max_running_requests=$maxrun" "$qualification_artifact/run_identity.txt"
grep -qx "cuda_graph_max_bs=$graph_max_bs" "$qualification_artifact/run_identity.txt"
# Older qualification artifacts did not record these two fields in
# run_identity.txt. Their checksummed launch command remains authoritative, so
# allow that legacy omission while still requiring the exact command flags
# immediately below. If either identity key is present, it must match.
for identity_check in \
  "scheduler_recv_interval=$scheduler_recv_interval" \
  "page_size=$page_size"; do
  identity_key="${identity_check%%=*}"
  if grep -q "^${identity_key}=" "$qualification_artifact/run_identity.txt"; then
    grep -qx "$identity_check" "$qualification_artifact/run_identity.txt"
  else
    printf '%s qualification_legacy_identity_missing key=%s artifact=%s\n' \
      "$(date --iso-8601=seconds)" "$identity_key" "$qualification_artifact"
  fi
done
grep -Eq -- "--max-running-requests[[:space:]]+${maxrun}([[:space:]]|$)" \
  "$qualification_artifact/sglang_command.txt"
grep -Eq -- "--cuda-graph-max-bs[[:space:]]+${graph_max_bs}([[:space:]]|$)" \
  "$qualification_artifact/sglang_command.txt"
grep -Eq -- "--scheduler-recv-interval[[:space:]]+${scheduler_recv_interval}([[:space:]]|$)" \
  "$qualification_artifact/sglang_command.txt"
grep -Eq -- "--page-size[[:space:]]+${page_size}([[:space:]]|$)" \
  "$qualification_artifact/sglang_command.txt"
if grep -q '^promotion_candidates=' "$qualification_decision"; then
  awk -F= -v expected="$qualification_name" '
    $1 == "promotion_candidates" {
      count = split($2, values, ",")
      for (i = 1; i <= count; i++) if (values[i] == expected) found = 1
    }
    END {exit !found}
  ' "$qualification_decision" || {
    echo "qualification point is absent from promotion_candidates" >&2
    exit 3
  }
fi

for manifest_path in $base_candidate_manifests; do
  [[ -f "$manifest_path" ]] || {
    echo "missing base candidate manifest: $manifest_path" >&2
    exit 1
  }
  jq -e 'all(.points[]; .status == "accepted")' "$manifest_path" >/dev/null || {
    echo "base candidate manifest contains non-accepted points: $manifest_path" >&2
    exit 3
  }
done

if [[ -n "$patch_path" ]]; then
  [[ -f "$patch_path" ]] || {
    echo "PATCH_PATH does not exist: $patch_path" >&2
    exit 2
  }
  [[ "$patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "PATCH_SHA256 must be a lowercase SHA256" >&2
    exit 2
  }
  [[ -n "$expected_route_regex" ]] || {
    echo "EXPECTED_ROUTE_REGEX is required for a patched confirmation" >&2
    exit 2
  }
  actual_patch_sha256="$(sha256sum "$patch_path" | awk '{print $1}')"
  [[ "$actual_patch_sha256" == "$patch_sha256" ]] || {
    echo "patch checksum mismatch: expected $patch_sha256 got $actual_patch_sha256" >&2
    exit 2
  }
else
  [[ -z "$patch_sha256" && -z "$expected_route_regex" \
    && -z "$expected_route_regex_2" && -z "$expected_route_regex_3" ]] || {
    echo "PATCH_SHA256 and route regexes require PATCH_PATH" >&2
    exit 2
  }
fi
if [[ -n "$aiter_patch_path" ]]; then
  [[ -f "$aiter_patch_path" ]] || {
    echo "AITER_PATCH_PATH does not exist: $aiter_patch_path" >&2
    exit 2
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

run_tag="$(date +%Y%m%dT%H%M%S%z)"
result="qwen35_pr2737_tp2ep1_c${conc}_${result_label}_maxrun${maxrun}_graph${graph_max_bs}_page${page_size}_${duration}s_confirm_${run_tag}"
archive="$archive_root/$result"
manifest="$shared_root/${result}.candidates.json"
evaluation_json="$shared_root/${result}.evaluation.json"
decision_path="$shared_root/${result}.decision.txt"

wait_clean() {
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --nodelist="$target_node" bash -s <<'PREFLIGHT'
set -euo pipefail
for attempt in $(seq 1 60); do
  dirty=0
  ss -ltn 2>/dev/null | grep -q ':8888 ' && dirty=1
  fuser /dev/kfd >/tmp/qwen35-frontier-confirm-kfd-users 2>/dev/null && dirty=1
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
printf '%s confirmation_start result=%s qualification=%s duration=%s conc=%s maxrun=%s graph_max_bs=%s scheduler_recv_interval=%s page_size=%s\n' \
  "$(date --iso-8601=seconds)" "$result" "$qualification_name" "$duration" \
  "$conc" "$maxrun" "$graph_max_bs" "$scheduler_recv_interval" "$page_size"

run_env=(
  TARGET_NODE="$target_node"
  ARCHIVE_ROOT="$archive_root"
  TRIGGER_JOB=99999999
  RESULT_NAME="$result"
  DURATION="$duration"
  CONC="$conc"
  MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun"
  CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs"
  SCHEDULER_RECV_INTERVAL_OVERRIDE="$scheduler_recv_interval"
  PAGE_SIZE_OVERRIDE="$page_size"
)
if [[ -n "$patch_path" ]]; then
  run_env+=(
    SGLANG_PATCH="$patch_path"
    SGLANG_PATCH_SHA256="$patch_sha256"
    SGLANG_GDN_DECODE_FUSION_LOG_LAYER_HITS=1
  )
fi
if [[ -n "$aiter_patch_path" ]]; then
  run_env+=(
    AITER_PATCH="$aiter_patch_path"
    AITER_PATCH_SHA256="$aiter_patch_sha256"
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
  exit 1
fi

grep -qx "max_running_requests=$maxrun" "$archive/run_identity.txt"
grep -qx "cuda_graph_max_bs=$graph_max_bs" "$archive/run_identity.txt"
grep -qx "scheduler_recv_interval=$scheduler_recv_interval" "$archive/run_identity.txt"
grep -qx "page_size=$page_size" "$archive/run_identity.txt"
grep -Eq -- "--max-running-requests[[:space:]]+${maxrun}([[:space:]]|$)" "$archive/sglang_command.txt"
grep -Eq -- "--cuda-graph-max-bs[[:space:]]+${graph_max_bs}([[:space:]]|$)" "$archive/sglang_command.txt"
grep -Eq -- "--scheduler-recv-interval[[:space:]]+${scheduler_recv_interval}([[:space:]]|$)" "$archive/sglang_command.txt"
grep -Eq -- "--page-size[[:space:]]+${page_size}([[:space:]]|$)" "$archive/sglang_command.txt"
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

if [[ -n "$patch_path" ]]; then
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
fi

wait_clean
validate_teardown "$archive/teardown.txt"

throughput="$(jq -r '.request_metrics.throughput.per_gpu.total_tput_tps' "$aggregate")"
interactivity="$(jq -r '.request_metrics.latency.full_response_intvty.p90' "$aggregate")"
profiled="$(jq -r '.request_accounting.records_profiled' "$aggregate")"
avg_power="$(jq -r '.avg_power_w' "$aggregate")"
candidate_name="${result_label}-c${conc}-maxrun${maxrun}-${duration}s-confirm"
jq -n \
  --arg name "$candidate_name" \
  --arg artifact "$archive" \
  --arg qualification_name "$qualification_name" \
  --arg qualification_manifest "$qualification_manifest" \
  --arg qualification_decision "$qualification_decision" \
  --arg patch_sha256 "${patch_sha256:-none}" \
  --arg aiter_patch_sha256 "${aiter_patch_sha256:-none}" \
  --argjson throughput "$throughput" \
  --argjson p90 "$interactivity" \
  --argjson conc "$conc" \
  --argjson maxrun "$maxrun" \
  --argjson graph_max_bs "$graph_max_bs" \
  --argjson scheduler_recv_interval "$scheduler_recv_interval" \
  --argjson page_size "$page_size" \
  --argjson duration "$duration" \
  --argjson profiled "$profiled" \
  --argjson avg_power "$avg_power" '
  {
    schema_version: 1,
    points: [{
      name: $name,
      status: "provisional",
      throughput_per_gpu_tokens_per_s: $throughput,
      p90_interactivity_tokens_per_s_user: $p90,
      artifact: $artifact,
      metadata: {
        evidence_stage: "sustained_confirmation_pending_postflight",
        concurrency: $conc,
        max_running_requests: $maxrun,
        cuda_graph_max_bs: $graph_max_bs,
        scheduler_recv_interval: $scheduler_recv_interval,
        page_size: $page_size,
        duration_seconds: $duration,
        profiled_requests: $profiled,
        avg_power_w: $avg_power,
        sglang_patch_sha256: $patch_sha256,
        aiter_patch_sha256: $aiter_patch_sha256,
        qualification_name: $qualification_name,
        qualification_manifest: $qualification_manifest,
        qualification_decision: $qualification_decision
      }
    }]
  }
' >"$manifest"

eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
eval_args+=(--candidates "$manifest" --include-provisional --json --output "$evaluation_json")
"${eval_args[@]}"

selected_anchor_count="$(jq --arg name "$candidate_name" \
  '[.selected[] | select(.selected_point == $name)] | length' "$evaluation_json")"
new_mean="$(jq -r '.new_mean' "$evaluation_json")"
relative_gain_pct="$(jq -r '.relative_mean_gain * 100' "$evaluation_json")"
remaining_mean_gain="$(jq -r '.remaining_mean_gain' "$evaluation_json")"

{
  printf 'candidate_name=%s\n' "$candidate_name"
  printf 'throughput_per_gpu=%s\n' "$throughput"
  printf 'p90_interactivity=%s\n' "$interactivity"
  printf 'candidate_selected_anchor_count=%s\n' "$selected_anchor_count"
  printf 'provisional_frontier_mean=%s\n' "$new_mean"
  printf 'provisional_relative_mean_gain_pct=%s\n' "$relative_gain_pct"
  printf 'remaining_mean_gain=%s\n' "$remaining_mean_gain"
  if (( selected_anchor_count > 0 )); then
    printf 'advance_to_full_node_postflight=1\n'
  else
    printf 'advance_to_full_node_postflight=0\n'
  fi
  printf 'archive=%s\nmanifest=%s\nevaluation=%s\n' \
    "$archive" "$manifest" "$evaluation_json"
} | tee "$decision_path"

if (( selected_anchor_count == 0 )); then
  echo "sustained candidate does not advance the current frozen frontier" >&2
  exit 4
fi

printf '%s confirmation_done archive=%s decision=%s\n' \
  "$(date --iso-8601=seconds)" "$archive" "$decision_path"
