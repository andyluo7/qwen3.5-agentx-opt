#!/usr/bin/env bash
#SBATCH --job-name=q35-pr34005-after
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr34005-after-pr35872-%j.out

# If the portfolio remains below target after the isolated PR #35872 bracket,
# test PR #34005 independently at the same selected maxrun-1 concurrency.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
previous_stdout="${PREVIOUS_STDOUT:?PREVIOUS_STDOUT is required}"
pr37113_stdout="${PR37113_STDOUT:?PR37113_STDOUT is required}"
client_prefix="${CLIENT_PREFIX:?CLIENT_PREFIX is required}"
first_ladder_manifest="${FIRST_LADDER_MANIFEST:?FIRST_LADDER_MANIFEST is required}"
maxrun5_manifest="${MAXRUN5_MANIFEST:?MAXRUN5_MANIFEST is required}"
duration="${DURATION:-900}"

client_manifest="$client_prefix.candidates.json"
patch_wrapper="$shared_root/run_qwen35_sglang_patch_bracket_node2.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_node2.sh"
patch_path="$shared_root/sglang_pr34005_draft_extend_lm_head_prune_instrumented.patch"
patch_sha256="ae408c01b4bb595bef711500161f554cf22b466609cf87bf58ea9c8dc1382d78"

for required in \
  "$previous_stdout" "$pr37113_stdout" "$client_manifest" \
  "$first_ladder_manifest" "$maxrun5_manifest" \
  "$patch_wrapper" "$point_launcher" "$patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

if grep -Fq 'skip_pr35872 reason=provisional_target_numerically_met' \
  "$previous_stdout"; then
  printf '%s skip_pr34005 reason=provisional_target_numerically_met upstream=%s\n' \
    "$(date --iso-8601=seconds)" "$previous_stdout"
  exit 0
fi

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

previous_summary="$(recover_summary "$previous_stdout" pr35872-rocm-topk1)"
pr37113_summary="$(recover_summary "$pr37113_stdout" pr37113-rocm-gdn-decode)"
for summary in "$previous_summary" "$pr37113_summary"; do
  [[ -n "$summary" && "$summary" == *.tsv ]] || {
    echo "could not recover a required patch summary" >&2
    exit 3
  }
  [[ "$(printf '%s\n' "$summary" | wc -l | tr -d ' ')" == 1 ]] || {
    echo "ambiguous patch summary: $summary" >&2
    exit 3
  }
done

previous_prefix="${previous_summary%.tsv}"
previous_manifest="$previous_prefix.candidates.json"
previous_evaluation="$previous_prefix.evaluation.json"
previous_decision="$previous_prefix.decision.txt"
pr37113_manifest="${pr37113_summary%.tsv}.candidates.json"
for required in \
  "$previous_manifest" "$previous_evaluation" "$previous_decision" \
  "$pr37113_manifest"; do
  [[ -f "$required" ]] || {
    echo "missing predecessor output: $required" >&2
    exit 1
  }
done
grep -Fqx "manifest=$previous_manifest" "$previous_decision" || {
  echo "PR #35872 decision is not bound to $previous_manifest" >&2
  exit 3
}
grep -Fqx "evaluation=$previous_evaluation" "$previous_decision" || {
  echo "PR #35872 decision is not bound to $previous_evaluation" >&2
  exit 3
}

if [[ "$(jq -r '.target_numerically_met' "$previous_evaluation")" == true ]]; then
  printf '%s skip_pr34005 reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$previous_evaluation"
  exit 0
fi

conc="$(awk -F'[ =]' '
  /starting_pr35872/ {
    for (i = 1; i <= NF; i++) if ($i == "concurrency") print $(i + 1)
  }
' "$previous_stdout")"
case "$conc" in
  4|12) ;;
  *)
    echo "invalid or ambiguous selected concurrency in $previous_stdout: $conc" >&2
    exit 3
    ;;
esac

actual_patch_sha256="$(sha256sum "$patch_path" | awk '{print $1}')"
[[ "$actual_patch_sha256" == "$patch_sha256" ]] || {
  echo "PR #34005 patch checksum mismatch: expected $patch_sha256 got $actual_patch_sha256" >&2
  exit 2
}

base_candidate_manifests="$first_ladder_manifest $maxrun5_manifest $client_manifest $pr37113_manifest $previous_manifest"
printf '%s starting_pr34005 concurrency=%s previous_evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$conc" "$previous_evaluation"

env \
  POINT_SCRIPT="$point_launcher" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  PATCH_LABEL=pr34005-draft-extend-lm-head-prune \
  EXPECTED_ROUTE_REGEX='EAGLE_DRAFT_EXTEND_LM_HEAD_BACKEND rows=selected backend=rocm' \
  DURATION="$duration" \
  CONC="$conc" \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  bash "$patch_wrapper"
