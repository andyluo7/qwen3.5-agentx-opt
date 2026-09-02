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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-client-edges-after-chain-%j.out

# Test C1 and C8 at maxrun 1 only if every source-patch screen in PATCH_CHAIN
# completed without numerically reaching the portfolio target. PATCH_CHAIN is
# a space-separated list of stdout-path|patch-label pairs.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:?BASE_CANDIDATE_MANIFESTS is required}"
patch_chain="${PATCH_CHAIN:?PATCH_CHAIN is required}"
duration="${DURATION:-900}"
client_wrapper="$shared_root/run_qwen35_pr2737_client_concurrency_bracket_node2_v2.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_node2.sh"

for required in "$client_wrapper" "$point_launcher"; do
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

declare -a patch_manifests=()
latest_evaluation=""
for entry in $patch_chain; do
  stdout_path="${entry%%|*}"
  patch_label="${entry#*|}"
  [[ "$stdout_path" != "$patch_label" ]] || {
    echo "invalid PATCH_CHAIN entry: $entry" >&2
    exit 2
  }
  [[ -f "$stdout_path" ]] || {
    echo "missing patch stdout: $stdout_path" >&2
    exit 1
  }
  if grep -Fq 'reason=provisional_target_numerically_met' "$stdout_path"; then
    printf '%s skip_client_edges reason=provisional_target_numerically_met upstream=%s\n' \
      "$(date --iso-8601=seconds)" "$stdout_path"
    exit 0
  fi
  summary="$(awk -v expected="$patch_label" '
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
  ' "$stdout_path")"
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
  latest_evaluation="$evaluation"
done

[[ -n "$latest_evaluation" ]] || {
  echo "PATCH_CHAIN did not contain any completed patch outputs" >&2
  exit 2
}
if [[ "$(jq -r '.target_numerically_met' "$latest_evaluation")" == true ]]; then
  printf '%s skip_client_edges reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$latest_evaluation"
  exit 0
fi

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
