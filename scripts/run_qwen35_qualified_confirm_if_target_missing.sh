#!/usr/bin/env bash
#SBATCH --job-name=q35-qualified-confirm
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-5
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=01:45:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-qualified-confirm-%j.out

# Sustain an already audited qualification point only while the accepted
# portfolio remains below the frozen target. A successful confirmation submits
# its own independent eight-GPU postflight.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
target_node="${TARGET_NODE:?TARGET_NODE is required}"
postflight_stdouts="${POSTFLIGHT_STDOUTS:?POSTFLIGHT_STDOUTS is required}"
prior_postflight_stdout="${PRIOR_POSTFLIGHT_STDOUT:-}"
qualification_manifest="${QUALIFICATION_MANIFEST:?QUALIFICATION_MANIFEST is required}"
qualification_decision="${QUALIFICATION_DECISION:?QUALIFICATION_DECISION is required}"
qualification_name="${QUALIFICATION_NAME:?QUALIFICATION_NAME is required}"
qualification_gate="${QUALIFICATION_GATE:?QUALIFICATION_GATE is required}"
result_label="${RESULT_LABEL:?RESULT_LABEL is required}"
conc="${CONC:?CONC is required}"
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
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
confirm="$shared_root/run_qwen35_frontier_confirm_v5.sh"
postflight_resolver="$shared_root/run_qwen35_frontier_postflight_after_confirmation.sh"
confirmation_stdout="$shared_root/qwen35-qualified-confirm-${job_id}.out"

for required in \
  "$evaluator" "$objective" "$confirm" "$postflight_resolver" \
  "$qualification_manifest" "$qualification_decision"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

declare -a accepted_manifests=()
for stdout_path in $postflight_stdouts; do
  [[ -f "$stdout_path" ]] || {
    echo "missing base postflight stdout: $stdout_path" >&2
    exit 1
  }
  manifest="$(sed -n 's/^accepted_manifest=//p' "$stdout_path")"
  [[ -n "$manifest" && -f "$manifest" ]] || {
    echo "missing accepted manifest from $stdout_path" >&2
    exit 1
  }
  [[ "$(printf '%s\n' "$manifest" | wc -l | tr -d ' ')" == 1 ]]
  jq -e '.points | length == 1 and .[0].status == "accepted"' \
    "$manifest" >/dev/null
  accepted_manifests+=("$manifest")
done
(( ${#accepted_manifests[@]} >= 4 )) || {
  echo "expected at least four base accepted manifests" >&2
  exit 3
}

if [[ -n "$prior_postflight_stdout" && -f "$prior_postflight_stdout" ]]; then
  prior_manifest="$(sed -n 's/^accepted_manifest=//p' "$prior_postflight_stdout")"
  if [[ -n "$prior_manifest" && -f "$prior_manifest" ]] \
    && [[ "$(printf '%s\n' "$prior_manifest" | wc -l | tr -d ' ')" == 1 ]] \
    && jq -e '.points | length == 1 and .[0].status == "accepted"' \
      "$prior_manifest" >/dev/null; then
    accepted_manifests+=("$prior_manifest")
    printf '%s included_prior_postflight manifest=%s stdout=%s\n' \
      "$(date --iso-8601=seconds)" "$prior_manifest" "$prior_postflight_stdout"
  fi
fi

precheck="$shared_root/qwen35-qualified-confirm-precheck-${job_id}.evaluation.json"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest in "${accepted_manifests[@]}"; do
  eval_args+=(--candidates "$manifest")
done
eval_args+=(--require-target --json --output "$precheck")
set +e
"${eval_args[@]}"
precheck_rc=$?
set -e
if (( precheck_rc == 0 )); then
  printf '%s skip_qualified_confirmation reason=accepted_target_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$precheck"
  exit 0
fi
(( precheck_rc == 1 )) || {
  echo "accepted portfolio evaluation failed with rc=$precheck_rc" >&2
  exit "$precheck_rc"
}

base_candidate_manifests="${accepted_manifests[*]}"
confirm_env=(
  TARGET_NODE="$target_node"
  QUALIFICATION_MANIFEST="$qualification_manifest"
  QUALIFICATION_DECISION="$qualification_decision"
  QUALIFICATION_NAME="$qualification_name"
  QUALIFICATION_GATE="$qualification_gate"
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests"
  RESULT_LABEL="$result_label"
  DURATION=3600
  CONC="$conc"
  MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun"
  CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs"
  SCHEDULER_RECV_INTERVAL_OVERRIDE="$scheduler_recv_interval"
  PAGE_SIZE_OVERRIDE="$page_size"
)
if [[ -n "$patch_path" ]]; then
  confirm_env+=(PATCH_PATH="$patch_path" PATCH_SHA256="$patch_sha256")
fi
if [[ -n "$aiter_patch_path" ]]; then
  confirm_env+=(AITER_PATCH_PATH="$aiter_patch_path" AITER_PATCH_SHA256="$aiter_patch_sha256")
fi
if [[ -n "$expected_route_regex" ]]; then
  confirm_env+=(EXPECTED_ROUTE_REGEX="$expected_route_regex")
fi
if [[ -n "$expected_route_regex_2" ]]; then
  confirm_env+=(EXPECTED_ROUTE_REGEX_2="$expected_route_regex_2")
fi
if [[ -n "$expected_route_regex_3" ]]; then
  confirm_env+=(EXPECTED_ROUTE_REGEX_3="$expected_route_regex_3")
fi

env "${confirm_env[@]}" bash "$confirm"

postflight_job="$(
  env \
    TARGET_NODE="$target_node" \
    EXPECTED_CONFIRMATION_JOB_ID="$job_id" \
    CONFIRMATION_STDOUT="$confirmation_stdout" \
    BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
    sbatch --parsable --dependency="afterok:$job_id" --nodelist="$target_node" \
      "$postflight_resolver"
)"
printf '%s submitted_qualified_postflight job_id=%s confirmation_job_id=%s\n' \
  "$(date --iso-8601=seconds)" "$postflight_job" "$job_id"
