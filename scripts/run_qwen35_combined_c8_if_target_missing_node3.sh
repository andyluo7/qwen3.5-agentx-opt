#!/usr/bin/env bash
#SBATCH --job-name=q35-combined-c8-if-needed
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-3
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=04:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-combined-c8-if-needed-%j.out

# If the accepted portfolio still misses the target, compare C8/maxrun-1 with
# repeated C12/maxrun-1 controls while holding the combined source overlays and
# all server settings fixed. C8 can advance the a03 throughput anchor without
# spending a run on a dominated high-concurrency point.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
target_node="${TARGET_NODE:-vultr-mi355x-3}"
accepted_manifests="${ACCEPTED_MANIFESTS:?ACCEPTED_MANIFESTS is required}"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
bracket="$shared_root/run_qwen35_pr2737_client_concurrency_bracket_node2.sh"
point="$shared_root/run_qwen35_pr2737_c12_exact_point_node2.sh"
patch_path="${PATCH_PATH:-$shared_root/sglang_pr35872_pr37465_combined_instrumented.patch}"
patch_sha256="${PATCH_SHA256:-d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3}"
aiter_patch_path="${AITER_PATCH_PATH:-$shared_root/aiter_pr5190_mtp_verify_attn_asm.patch}"
aiter_patch_sha256="${AITER_PATCH_SHA256:-10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09}"
duration="${DURATION:-900}"

for required in \
  "$evaluator" "$objective" "$bracket" "$point" \
  "$patch_path" "$aiter_patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done
[[ "$(sha256sum "$patch_path" | awk '{print $1}')" == "$patch_sha256" ]]
[[ "$(sha256sum "$aiter_patch_path" | awk '{print $1}')" == "$aiter_patch_sha256" ]]

declare -a manifests=()
for manifest in $accepted_manifests; do
  [[ -f "$manifest" ]] || {
    echo "missing accepted manifest: $manifest" >&2
    exit 1
  }
  jq -e 'all(.points[]; .status == "accepted")' "$manifest" >/dev/null || {
    echo "manifest contains non-accepted points: $manifest" >&2
    exit 3
  }
  manifests+=("$manifest")
done
(( ${#manifests[@]} >= 2 )) || {
  echo "expected at least two accepted manifests" >&2
  exit 3
}

precheck="$shared_root/qwen35-combined-c8-precheck-${SLURM_JOB_ID}.evaluation.json"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest in "${manifests[@]}"; do
  eval_args+=(--candidates "$manifest")
done
eval_args+=(--require-target --json --output "$precheck")

set +e
"${eval_args[@]}"
precheck_rc=$?
set -e
if (( precheck_rc == 0 )); then
  printf '%s skip_combined_c8 reason=accepted_target_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$precheck"
  exit 0
fi
(( precheck_rc == 1 )) || {
  echo "accepted portfolio evaluation failed with rc=$precheck_rc" >&2
  exit "$precheck_rc"
}

base_candidate_manifests="${manifests[*]}"
printf '%s starting_combined_c8 reason=accepted_target_missing evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$precheck"

env \
  TARGET_NODE="$target_node" \
  POINT_SCRIPT="$point" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  AITER_PATCH_PATH="$aiter_patch_path" \
  AITER_PATCH_SHA256="$aiter_patch_sha256" \
  PATCH_LABEL=pr35872-pr37465-aiter5190-mtpverifyasm \
  EXPECTED_ROUTE_REGEX='EAGLE_TOPK1_BACKEND phase=draft_decode backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_2='EAGLE_TOPK1_BACKEND phase=draft_extend backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_3='module_mtp_verify_attn_asm|mtp_verify_attn_fwd_asm' \
  DURATION="$duration" \
  CONTROL_CONC=12 \
  CANDIDATE_CONCS=8 \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  CONTROL_PAGE_SIZE=16 \
  CANDIDATE_PAGE_SIZE=16 \
  CONTROL_SCHEDULER_RECV_INTERVAL=30 \
  CANDIDATE_SCHEDULER_RECV_INTERVAL=30 \
  bash "$bracket"
