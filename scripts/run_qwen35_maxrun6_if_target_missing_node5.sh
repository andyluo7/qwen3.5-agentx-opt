#!/usr/bin/env bash
#SBATCH --job-name=q35-maxrun6-if-needed
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-5
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=04:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-maxrun6-if-needed-%j.out

# If the accepted portfolio still misses the frozen target, run a controlled
# C12 maxrun5 -> maxrun6 -> maxrun5 screen with the qualified SGLang/AITER
# overlays. A selected maxrun6 point is then submitted for a 3,600-second
# confirmation; that confirmation submits its own full-node postflight.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
target_node="${TARGET_NODE:-vultr-mi355x-5}"
postflight_stdouts="${POSTFLIGHT_STDOUTS:?POSTFLIGHT_STDOUTS is required}"
prior_postflight_stdout="${PRIOR_POSTFLIGHT_STDOUT:-}"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
ladder="$shared_root/run_qwen35_pr2737_c12_maxrun_ladder_node2.sh"
confirm="$shared_root/run_qwen35_confirm_combined_candidate_after_screen.sh"
patch_path="${PATCH_PATH:-$shared_root/sglang_pr35872_pr37465_combined_instrumented.patch}"
patch_sha256="${PATCH_SHA256:-d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3}"
aiter_patch_path="${AITER_PATCH_PATH:-$shared_root/aiter_pr5190_mtp_verify_attn_asm.patch}"
aiter_patch_sha256="${AITER_PATCH_SHA256:-10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09}"
screen_stdout="$shared_root/qwen35-maxrun6-if-needed-${job_id}.out"

for required in \
  "$evaluator" "$objective" "$ladder" "$confirm" \
  "$patch_path" "$aiter_patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done
[[ "$(sha256sum "$patch_path" | awk '{print $1}')" == "$patch_sha256" ]]
[[ "$(sha256sum "$aiter_patch_path" | awk '{print $1}')" == "$aiter_patch_sha256" ]]

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
    && jq -e '.points | length == 1 and .[0].status == "accepted"' \
      "$prior_manifest" >/dev/null; then
    accepted_manifests+=("$prior_manifest")
  fi
fi

precheck="$shared_root/qwen35-maxrun6-precheck-${job_id}.evaluation.json"
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
  printf '%s skip_maxrun6 reason=accepted_target_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$precheck"
  exit 0
fi
(( precheck_rc == 1 )) || {
  echo "accepted portfolio evaluation failed with rc=$precheck_rc" >&2
  exit "$precheck_rc"
}

base_candidate_manifests="${accepted_manifests[*]}"
printf '%s starting_maxrun6_screen reason=accepted_target_missing evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$precheck"

env \
  TARGET_NODE="$target_node" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  DURATION=900 \
  CONTROL_MAXRUN=5 \
  CANDIDATE_MAXRUNS=6 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  PAGE_SIZE_OVERRIDE=16 \
  SCHEDULER_RECV_INTERVAL_OVERRIDE=30 \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  AITER_PATCH_PATH="$aiter_patch_path" \
  AITER_PATCH_SHA256="$aiter_patch_sha256" \
  PATCH_LABEL=pr35872-pr37465-aiter5190-mtpverifyasm \
  EXPECTED_ROUTE_REGEX='EAGLE_TOPK1_BACKEND phase=draft_decode backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_2='EAGLE_TOPK1_BACKEND phase=draft_extend backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_3='module_mtp_verify_attn_asm|mtp_verify_attn_fwd_asm' \
  bash "$ladder"

confirmation_job="$(
  env \
    TARGET_NODE="$target_node" \
    SCREEN_STDOUT="$screen_stdout" \
    POSTFLIGHT_STDOUTS="$postflight_stdouts" \
    CANDIDATE_CONC=12 \
    CANDIDATE_MAXRUN=6 \
    CANDIDATE_PAGE_SIZE=16 \
    RESULT_LABEL=pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6 \
    QUALIFICATION_GATE=advance_selected_candidates_to_isolated_bracket=1 \
    PATCH_PATH="$patch_path" \
    PATCH_SHA256="$patch_sha256" \
    AITER_PATCH_PATH="$aiter_patch_path" \
    AITER_PATCH_SHA256="$aiter_patch_sha256" \
    sbatch --parsable --dependency="afterok:$job_id" --nodelist="$target_node" \
      "$confirm"
)"
printf '%s submitted_maxrun6_confirmation job_id=%s screen_job_id=%s\n' \
  "$(date --iso-8601=seconds)" "$confirmation_job" "$job_id"
