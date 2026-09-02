#!/usr/bin/env bash
#SBATCH --job-name=q35-recv10-after-patches
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-recv10-after-patches-%j.out

# Test scheduler receive interval 10 on top of the qualified PR #35872 C4
# configuration. This job is intended to depend on both the isolated patch
# chain and the page-size bracket, so it evaluates against every completed
# frontier-capable screen before deciding whether another A/B is necessary.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:?BASE_CANDIDATE_MANIFESTS is required}"
pr35872_stdout="${PR35872_STDOUT:?PR35872_STDOUT is required}"
pr34005_stdout="${PR34005_STDOUT:?PR34005_STDOUT is required}"
pr33778_stdout="${PR33778_STDOUT:?PR33778_STDOUT is required}"
edge_stdout="${EDGE_STDOUT:?EDGE_STDOUT is required}"
page64_stdout="${PAGE64_STDOUT:?PAGE64_STDOUT is required}"
duration="${DURATION:-900}"
wrapper="$shared_root/run_qwen35_pr2737_client_concurrency_bracket_v3.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_page64_v2.sh"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
patch_path="$shared_root/sglang_pr35872_rocm_topk1_instrumented.patch"
patch_sha256=2cb017337b955402d87e6690f0bc9cb4c2be31f9be1102ecf2c34f4606d2780a

for required in \
  "$pr35872_stdout" "$pr34005_stdout" "$pr33778_stdout" \
  "$edge_stdout" "$page64_stdout" "$wrapper" "$point_launcher" \
  "$evaluator" "$objective" "$patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done
for manifest_path in $base_candidate_manifests; do
  [[ -f "$manifest_path" ]] || {
    echo "missing base candidate manifest: $manifest_path" >&2
    exit 1
  }
done
[[ "$(sha256sum "$patch_path" | awk '{print $1}')" == "$patch_sha256" ]] || {
  echo "PR #35872 patch checksum mismatch" >&2
  exit 2
}

recover_summary() {
  local stdout_path="$1"
  local expected_label="${2:-}"
  awk -v expected="$expected_label" '
    /campaign_start/ {
      matched = (expected == "")
      for (i = 1; i <= NF; i++) {
        if ($i == "patch_label=" expected) matched = 1
      }
      if (matched) {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^summary=/) {
            sub(/^summary=/, "", $i)
            print $i
          }
        }
      }
    }
  ' "$stdout_path"
}

manifest_for_campaign() {
  local stdout_path="$1"
  local expected_label="${2:-}"
  local summary prefix manifest evaluation decision
  summary="$(recover_summary "$stdout_path" "$expected_label")"
  [[ -n "$summary" && "$summary" == *.tsv ]] || {
    echo "could not recover campaign summary from $stdout_path" >&2
    exit 3
  }
  [[ "$(printf '%s\n' "$summary" | wc -l | tr -d ' ')" == 1 ]] || {
    echo "ambiguous campaign summary in $stdout_path" >&2
    exit 3
  }
  prefix="${summary%.tsv}"
  manifest="$prefix.candidates.json"
  evaluation="$prefix.evaluation.json"
  decision="$prefix.decision.txt"
  for required in "$manifest" "$evaluation" "$decision"; do
    [[ -f "$required" ]] || {
      echo "missing campaign output: $required" >&2
      exit 1
    }
  done
  grep -Fqx "manifest=$manifest" "$decision"
  grep -Fqx "evaluation=$evaluation" "$decision"
  printf '%s\n' "$manifest"
}

pr35872_manifest="$(manifest_for_campaign "$pr35872_stdout" pr35872-rocm-topk1)"
grep -Fqx 'advance_to_sustained_confirmation=1' \
  "${pr35872_manifest%.candidates.json}.decision.txt" || {
  printf '%s skip_scheduler_recv10 reason=pr35872_not_qualified\n' \
    "$(date --iso-8601=seconds)"
  exit 0
}

campaign_manifests=("$pr35872_manifest")
for entry in \
  "$pr34005_stdout|pr34005-draft-extend-lm-head-prune" \
  "$pr33778_stdout|pr33778-strided-target-verify-qkv" \
  "$edge_stdout|" \
  "$page64_stdout|"; do
  stdout_path="${entry%%|*}"
  expected_label="${entry#*|}"
  if grep -Fq 'campaign_start' "$stdout_path"; then
    campaign_manifests+=("$(manifest_for_campaign "$stdout_path" "$expected_label")")
  fi
done

pre_evaluation="$shared_root/qwen35-recv10-precheck-${SLURM_JOB_ID}.json"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
for manifest_path in "${campaign_manifests[@]}"; do
  eval_args+=(--candidates "$manifest_path")
  base_candidate_manifests+=" $manifest_path"
done
eval_args+=(--include-provisional --json --output "$pre_evaluation")
"${eval_args[@]}"

if [[ "$(jq -r '.target_numerically_met' "$pre_evaluation")" == true ]]; then
  printf '%s skip_scheduler_recv10 reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$pre_evaluation"
  exit 0
fi

printf '%s starting_scheduler_recv10 concurrency=4 maxrun=1 patch_label=pr35872-rocm-topk1 previous_evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$pre_evaluation"
env \
  TARGET_NODE=vultr-mi355x-2 \
  POINT_SCRIPT="$point_launcher" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  PATCH_LABEL=pr35872-rocm-topk1 \
  EXPECTED_ROUTE_REGEX='EAGLE_TOPK1_BACKEND phase=draft_decode backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_2='EAGLE_TOPK1_BACKEND phase=draft_extend backend=triton_split_argmax' \
  DURATION="$duration" \
  CONTROL_CONC=4 \
  CANDIDATE_CONCS=4 \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  CONTROL_PAGE_SIZE=16 \
  CANDIDATE_PAGE_SIZE=16 \
  CONTROL_SCHEDULER_RECV_INTERVAL=30 \
  CANDIDATE_SCHEDULER_RECV_INTERVAL=10 \
  bash "$wrapper"
