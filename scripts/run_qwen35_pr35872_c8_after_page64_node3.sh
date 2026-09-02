#!/usr/bin/env bash
#SBATCH --job-name=q35-topk1-c8-after
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-topk1-c8-after-%j.out

# Extend a positively qualified #35872 result to C8 only when the measured C4
# uplift projects the C8 point onto at least one frozen throughput anchor and
# the combined provisional portfolio remains below target. The unpatched C8
# point need not already be selected: a small patch gain can make a near-frontier
# point useful, and that is exactly what this bounded screen is meant to test.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:?BASE_CANDIDATE_MANIFESTS is required}"
edge_stdout="${EDGE_STDOUT:?EDGE_STDOUT is required}"
topk_stdout="${TOPK_STDOUT:?TOPK_STDOUT is required}"
page64_stdout="${PAGE64_STDOUT:?PAGE64_STDOUT is required}"
duration="${DURATION:-900}"
wrapper="$shared_root/run_qwen35_sglang_patch_bracket_node2.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_page64_v2.sh"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
patch_path="$shared_root/sglang_pr35872_rocm_topk1_instrumented.patch"
patch_sha256=2cb017337b955402d87e6690f0bc9cb4c2be31f9be1102ecf2c34f4606d2780a

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

append_campaign() {
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
  grep -Fqx "manifest=$manifest" "$decision" || {
    echo "decision is not bound to $manifest" >&2
    exit 3
  }
  grep -Fqx "evaluation=$evaluation" "$decision" || {
    echo "decision is not bound to $evaluation" >&2
    exit 3
  }
  printf '%s\n' "$manifest"
}

for required in \
  "$edge_stdout" "$topk_stdout" "$page64_stdout" "$wrapper" \
  "$point_launcher" "$evaluator" "$objective" "$patch_path"; do
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

edge_manifest="$(append_campaign "$edge_stdout")"
topk_summary="$(recover_summary "$topk_stdout" pr35872-rocm-topk1)"
topk_manifest="$(append_campaign "$topk_stdout" pr35872-rocm-topk1)"
base_candidate_manifests+=" $edge_manifest $topk_manifest"
grep -Fqx 'advance_to_sustained_confirmation=1' \
  "${topk_manifest%.candidates.json}.decision.txt" || {
  printf '%s skip_pr35872_c8 reason=c4_topk1_not_qualified\n' \
    "$(date --iso-8601=seconds)"
  exit 0
}

if grep -Fq 'skip_page64 reason=provisional_target_numerically_met' "$page64_stdout"; then
  printf '%s skip_pr35872_c8 reason=provisional_target_numerically_met upstream=%s\n' \
    "$(date --iso-8601=seconds)" "$page64_stdout"
  exit 0
fi
page64_summary="$(recover_summary "$page64_stdout")"
if [[ -n "$page64_summary" ]]; then
  page64_manifest="$(append_campaign "$page64_stdout")"
  base_candidate_manifests+=" $page64_manifest"
else
  page64_manifest=""
fi

pre_evaluation="$shared_root/qwen35-pr35872-c8-precheck-${SLURM_JOB_ID}.json"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
eval_args+=(--include-provisional --json --output "$pre_evaluation")
"${eval_args[@]}"

if [[ "$(jq -r '.target_numerically_met' "$pre_evaluation")" == true ]]; then
  printf '%s skip_pr35872_c8 reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$pre_evaluation"
  exit 0
fi

c8_name="$(jq -r \
  '[.points[] | select((.metadata.concurrency // 0) == 8)] | .[0].name // empty' \
  "$edge_manifest")"
[[ -n "$c8_name" ]] || {
  echo "edge manifest does not contain a C8 candidate" >&2
  exit 3
}
c8_throughput="$(jq -r --arg name "$c8_name" \
  '.points[] | select(.name == $name) | .throughput_per_gpu_tokens_per_s' \
  "$edge_manifest")"
c8_p90="$(jq -r --arg name "$c8_name" \
  '.points[] | select(.name == $name) | .p90_interactivity_tokens_per_s_user' \
  "$edge_manifest")"
read -r topk_control1_p90 topk_candidate_p90 topk_control2_p90 < <(
  awk -F '\t' '
    $1 == "control1" {control1 = $4}
    $1 == "candidate" {candidate = $4}
    $1 == "control2" {control2 = $4}
    END {print control1, candidate, control2}
  ' "$topk_summary"
)
for value in \
  "$c8_throughput" "$c8_p90" \
  "$topk_control1_p90" "$topk_candidate_p90" "$topk_control2_p90"; do
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "invalid numeric value in C8 projection: $value" >&2
    exit 3
  }
done
projected_c8_p90="$(awk \
  -v base="$c8_p90" \
  -v control1="$topk_control1_p90" \
  -v candidate="$topk_candidate_p90" \
  -v control2="$topk_control2_p90" '
  BEGIN {
    conservative_control = control1 > control2 ? control1 : control2
    printf "%.8f", base * candidate / conservative_control
  }')"
projected_anchor_count="$(jq \
  --argjson throughput "$c8_throughput" \
  --argjson projected_p90 "$projected_c8_p90" '
  [.selected[]
   | select(
       .throughput_floor <= $throughput
       and .selected_p90 < $projected_p90
     )]
  | length
' "$pre_evaluation")"
if (( projected_anchor_count == 0 )); then
  printf '%s skip_pr35872_c8 reason=conservative_projection_not_frontier c8_throughput=%s c8_p90=%s projected_p90=%s evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$c8_throughput" "$c8_p90" \
    "$projected_c8_p90" "$pre_evaluation"
  exit 0
fi

printf '%s starting_pr35872_c8 previous_evaluation=%s page64_manifest=%s c8_throughput=%s c8_p90=%s projected_p90=%s projected_anchor_count=%s\n' \
  "$(date --iso-8601=seconds)" "$pre_evaluation" "${page64_manifest:-none}" \
  "$c8_throughput" "$c8_p90" "$projected_c8_p90" "$projected_anchor_count"
env \
  TARGET_NODE=vultr-mi355x-3 \
  POINT_SCRIPT="$point_launcher" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  PATCH_LABEL=pr35872-rocm-topk1-c8 \
  EXPECTED_ROUTE_REGEX='EAGLE_TOPK1_BACKEND phase=draft_decode backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_2='EAGLE_TOPK1_BACKEND phase=draft_extend backend=triton_split_argmax' \
  DURATION="$duration" \
  CONC=8 \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  PAGE_SIZE_OVERRIDE=16 \
  bash "$wrapper"
