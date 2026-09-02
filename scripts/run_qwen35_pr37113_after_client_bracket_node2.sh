#!/usr/bin/env bash
#SBATCH --job-name=q35-pr37113-after
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr37113-after-client-%j.out

# Run the first source-patch bracket at the maxrun-1 client concurrency that
# remains selected after the C12 -> C4 -> C12 qualification. The wrapper is
# intended to be submitted with afterok:<client-bracket-job> so it never races
# incomplete artifacts or occupies GPUs while waiting for the decision.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
client_prefix="${CLIENT_PREFIX:?CLIENT_PREFIX is required}"
first_ladder_manifest="${FIRST_LADDER_MANIFEST:?FIRST_LADDER_MANIFEST is required}"
maxrun5_manifest="${MAXRUN5_MANIFEST:?MAXRUN5_MANIFEST is required}"
duration="${DURATION:-900}"

client_manifest="$client_prefix.candidates.json"
client_evaluation="$client_prefix.evaluation.json"
client_decision="$client_prefix.decision.txt"
client_summary="$client_prefix.tsv"
patch_wrapper="$shared_root/run_qwen35_sglang_patch_bracket_node2.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_node2.sh"
patch_path="$shared_root/sglang_pr37113_rocm_gdn_decode.patch"
patch_sha256="aca9ddc78be1e7dce15251ee774c3fef2ed3275865823816fefbcc13c895854f"
candidate_name="exact-pr2737-c4-maxrun1-graph24-${duration}s-screen"

for required in \
  "$client_manifest" "$client_evaluation" "$client_decision" "$client_summary" \
  "$first_ladder_manifest" "$maxrun5_manifest" \
  "$patch_wrapper" "$point_launcher" "$patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

grep -Fqx "manifest=$client_manifest" "$client_decision" || {
  echo "client decision is not bound to $client_manifest" >&2
  exit 3
}
grep -Fqx "evaluation=$client_evaluation" "$client_decision" || {
  echo "client decision is not bound to $client_evaluation" >&2
  exit 3
}

if [[ "$(jq -r '.target_numerically_met' "$client_evaluation")" == true ]]; then
  printf '%s skip_pr37113 reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$client_evaluation"
  exit 0
fi

actual_patch_sha256="$(sha256sum "$patch_path" | awk '{print $1}')"
[[ "$actual_patch_sha256" == "$patch_sha256" ]] || {
  echo "PR #37113 patch checksum mismatch: expected $patch_sha256 got $actual_patch_sha256" >&2
  exit 2
}

selected_anchor_count="$(jq --arg name "$candidate_name" \
  '[.selected[] | select(.selected_point == $name)] | length' \
  "$client_evaluation")"
promotion_candidates="$(awk -F= '$1 == "promotion_candidates" {print $2}' \
  "$client_decision")"
control_drift_ok="$(awk -F= '$1 == "control_drift_ok" {print $2}' \
  "$client_decision")"
read -r control1_p90 candidate_p90 control2_p90 < <(
  awk -F '\t' '
    $1 == "control1" {control1 = $5}
    $1 == "candidate_c4" {candidate = $5}
    $1 == "control2" {control2 = $5}
    END {print control1, candidate, control2}
  ' "$client_summary"
)
candidate_beats_both_controls_p90="$(awk \
  -v c1="$control1_p90" -v candidate="$candidate_p90" -v c2="$control2_p90" \
  'BEGIN {print (candidate > c1 && candidate > c2) ? 1 : 0}')"

conc=12
if [[ "$selected_anchor_count" -gt 0 \
  && "$control_drift_ok" == 1 \
  && "$candidate_beats_both_controls_p90" == 1 ]]; then
  case ",$promotion_candidates," in
    *",$candidate_name,"*) conc=4 ;;
    *)
      echo "C4 is selected but absent from the drift-gated promotion list" >&2
      exit 3
      ;;
  esac
fi

base_candidate_manifests="$first_ladder_manifest $maxrun5_manifest $client_manifest"
printf '%s selected_pr37113_control concurrency=%s c4_selected_anchor_count=%s control_drift_ok=%s c4_beats_both_controls_p90=%s control1_p90=%s candidate_p90=%s control2_p90=%s client_prefix=%s\n' \
  "$(date --iso-8601=seconds)" "$conc" "$selected_anchor_count" \
  "$control_drift_ok" "$candidate_beats_both_controls_p90" \
  "$control1_p90" "$candidate_p90" "$control2_p90" "$client_prefix"

env \
  POINT_SCRIPT="$point_launcher" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  PATCH_LABEL=pr37113-rocm-gdn-decode \
  EXPECTED_ROUTE_REGEX='GDN_FUSED_DECODE_BACKEND' \
  DURATION="$duration" \
  CONC="$conc" \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  bash "$patch_wrapper"
