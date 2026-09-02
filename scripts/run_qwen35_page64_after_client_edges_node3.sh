#!/usr/bin/env bash
#SBATCH --job-name=q35-page64-after-edges
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-page64-after-edges-%j.out

# Run a page-size-64 A/B only when the completed C1/C8 edge screen has not
# already moved the provisional 12-anchor portfolio to the numerical target.
# The comparison is C4/page16 -> C4/page64 -> C4/page16 at maxrun 1, so the
# only serving variable is KV page size and every arm remains frontier-capable.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
edge_stdout="${EDGE_STDOUT:?EDGE_STDOUT is required}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:?BASE_CANDIDATE_MANIFESTS is required}"
duration="${DURATION:-900}"
wrapper="${CLIENT_WRAPPER:-$shared_root/run_qwen35_pr2737_client_concurrency_bracket_page64_v2.sh}"
point_launcher="${POINT_SCRIPT:-$shared_root/run_qwen35_pr2737_lowconc_exact_point_page64_v2.sh}"

for required in "$edge_stdout" "$wrapper" "$point_launcher"; do
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

edge_summary="$(awk '
  /campaign_start/ {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^summary=/) {
        sub(/^summary=/, "", $i)
        print $i
      }
    }
  }
' "$edge_stdout")"
[[ -n "$edge_summary" && "$edge_summary" == *.tsv ]] || {
  echo "could not recover edge summary from $edge_stdout" >&2
  exit 3
}
[[ "$(printf '%s\n' "$edge_summary" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous edge summary in $edge_stdout" >&2
  exit 3
}

edge_prefix="${edge_summary%.tsv}"
edge_manifest="$edge_prefix.candidates.json"
edge_evaluation="$edge_prefix.evaluation.json"
edge_decision="$edge_prefix.decision.txt"
for required in "$edge_manifest" "$edge_evaluation" "$edge_decision"; do
  [[ -f "$required" ]] || {
    echo "missing edge output: $required" >&2
    exit 1
  }
done
grep -Fqx "manifest=$edge_manifest" "$edge_decision" || {
  echo "edge decision is not bound to $edge_manifest" >&2
  exit 3
}
grep -Fqx "evaluation=$edge_evaluation" "$edge_decision" || {
  echo "edge decision is not bound to $edge_evaluation" >&2
  exit 3
}

if [[ "$(jq -r '.target_numerically_met' "$edge_evaluation")" == true ]]; then
  printf '%s skip_page64 reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$edge_evaluation"
  exit 0
fi

base_candidate_manifests+=" $edge_manifest"
printf '%s starting_page64 concurrency=4 maxrun=1 previous_evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$edge_evaluation"

env \
  TARGET_NODE=vultr-mi355x-3 \
  POINT_SCRIPT="$point_launcher" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  DURATION="$duration" \
  CONTROL_CONC=4 \
  CANDIDATE_CONCS=4 \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  CONTROL_PAGE_SIZE=16 \
  CANDIDATE_PAGE_SIZE=64 \
  bash "$wrapper"
