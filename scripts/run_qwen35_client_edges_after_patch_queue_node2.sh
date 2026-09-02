#!/usr/bin/env bash
#SBATCH --job-name=q35-client-edges
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=03:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-client-edges-after-patches-%j.out

# If the isolated source-patch queue remains below the numerical screening
# target, measure the two still-unmeasured maxrun-1 client loads that can change
# the frozen frontier: C1 can advance a01, while C8 can advance a01-a03.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
client_prefix="${CLIENT_PREFIX:?CLIENT_PREFIX is required}"
first_ladder_manifest="${FIRST_LADDER_MANIFEST:?FIRST_LADDER_MANIFEST is required}"
maxrun5_manifest="${MAXRUN5_MANIFEST:?MAXRUN5_MANIFEST is required}"
pr37113_stdout="${PR37113_STDOUT:?PR37113_STDOUT is required}"
pr35872_stdout="${PR35872_STDOUT:?PR35872_STDOUT is required}"
pr34005_stdout="${PR34005_STDOUT:?PR34005_STDOUT is required}"
pr33778_stdout="${PR33778_STDOUT:?PR33778_STDOUT is required}"
duration="${DURATION:-900}"

client_manifest="$client_prefix.candidates.json"
client_wrapper="$shared_root/run_qwen35_pr2737_client_concurrency_bracket_node2_v2.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_node2.sh"

for required in \
  "$client_manifest" "$first_ladder_manifest" "$maxrun5_manifest" \
  "$pr37113_stdout" "$pr35872_stdout" "$pr34005_stdout" \
  "$pr33778_stdout" "$client_wrapper" "$point_launcher"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

for stdout_path in \
  "$pr37113_stdout" "$pr35872_stdout" "$pr34005_stdout" "$pr33778_stdout"; do
  if grep -Fq 'reason=provisional_target_numerically_met' "$stdout_path"; then
    printf '%s skip_client_edges reason=provisional_target_numerically_met upstream=%s\n' \
      "$(date --iso-8601=seconds)" "$stdout_path"
    exit 0
  fi
done

recover_summary() {
  local stdout_path="$1"
  local patch_label="$2"
  awk -v expected="$patch_label" '
    /campaign_start/ {
      matched = 0
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

declare -a patch_manifests=()
declare -a patch_evaluations=()
while IFS='|' read -r stdout_path patch_label; do
  summary="$(recover_summary "$stdout_path" "$patch_label")"
  [[ -n "$summary" && "$summary" == *.tsv ]] || {
    echo "could not recover $patch_label summary from $stdout_path" >&2
    exit 3
  }
  [[ "$(printf '%s\n' "$summary" | wc -l | tr -d ' ')" == 1 ]] || {
    echo "ambiguous $patch_label summary in $stdout_path" >&2
    exit 3
  }
  prefix="${summary%.tsv}"
  manifest="$prefix.candidates.json"
  evaluation="$prefix.evaluation.json"
  decision="$prefix.decision.txt"
  for required in "$manifest" "$evaluation" "$decision"; do
    [[ -f "$required" ]] || {
      echo "missing $patch_label output: $required" >&2
      exit 1
    }
  done
  grep -Fqx "manifest=$manifest" "$decision" || {
    echo "$patch_label decision is not bound to $manifest" >&2
    exit 3
  }
  grep -Fqx "evaluation=$evaluation" "$decision" || {
    echo "$patch_label decision is not bound to $evaluation" >&2
    exit 3
  }
  patch_manifests+=("$manifest")
  patch_evaluations+=("$evaluation")
done <<EOF
$pr37113_stdout|pr37113-rocm-gdn-decode
$pr35872_stdout|pr35872-rocm-topk1
$pr34005_stdout|pr34005-draft-extend-lm-head-prune
$pr33778_stdout|pr33778-strided-target-verify-qkv
EOF

latest_evaluation="${patch_evaluations[${#patch_evaluations[@]} - 1]}"
if [[ "$(jq -r '.target_numerically_met' "$latest_evaluation")" == true ]]; then
  printf '%s skip_client_edges reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$latest_evaluation"
  exit 0
fi

base_candidate_manifests="$first_ladder_manifest $maxrun5_manifest $client_manifest"
for manifest in "${patch_manifests[@]}"; do
  base_candidate_manifests+=" $manifest"
done

printf '%s starting_client_edges candidate_concurrencies=1,8 previous_evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$latest_evaluation"

env \
  POINT_SCRIPT="$point_launcher" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  DURATION="$duration" \
  CONTROL_CONC=12 \
  CANDIDATE_CONCS='1 8' \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  bash "$client_wrapper"
