#!/usr/bin/env bash
#SBATCH --job-name=q35-combined-c4-confirm
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-3
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=01:45:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-combined-c4-confirm-after-screen-%j.out

# Sustain the conditional combined-overlay C4 winner only when its completed
# A/B/A screen actually promoted it. A skipped or dominated screen exits
# without benchmarking. A successful confirmation submits its own independent
# full-node postflight, bound to this job's stdout and candidate manifest.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
target_node="${TARGET_NODE:-vultr-mi355x-3}"
screen_stdout="${SCREEN_STDOUT:?SCREEN_STDOUT is required}"
postflight_stdouts="${POSTFLIGHT_STDOUTS:?POSTFLIGHT_STDOUTS is required}"
confirm="$shared_root/run_qwen35_frontier_confirm_v4.sh"
postflight_resolver="$shared_root/run_qwen35_frontier_postflight_after_confirmation.sh"
patch_path="${PATCH_PATH:-$shared_root/sglang_pr35872_pr37465_combined_instrumented.patch}"
patch_sha256="${PATCH_SHA256:-d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3}"
aiter_patch_path="${AITER_PATCH_PATH:-$shared_root/aiter_pr5190_mtp_verify_attn_asm.patch}"
aiter_patch_sha256="${AITER_PATCH_SHA256:-10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09}"
confirmation_stdout="$shared_root/qwen35-combined-c4-confirm-after-screen-${job_id}.out"

for required in \
  "$screen_stdout" "$confirm" "$postflight_resolver" \
  "$patch_path" "$aiter_patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

if grep -Fq 'skip_combined_c4 reason=accepted_target_met' "$screen_stdout"; then
  printf '%s skip_combined_c4_confirmation reason=accepted_target_met screen=%s\n' \
    "$(date --iso-8601=seconds)" "$screen_stdout"
  exit 0
fi

screen_decision="$(awk '
  /campaign_done/ {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^decision=/) {
        sub(/^decision=/, "", $i)
        print $i
      }
    }
  }
' "$screen_stdout")"
[[ -n "$screen_decision" ]] || {
  echo "could not recover the C4 screen decision from $screen_stdout" >&2
  exit 3
}
[[ "$(printf '%s\n' "$screen_decision" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous C4 screen decision in $screen_stdout" >&2
  exit 3
}
[[ -f "$screen_decision" ]] || {
  echo "missing C4 screen decision: $screen_decision" >&2
  exit 1
}

if ! grep -Fqx 'advance_to_sustained_confirmation=1' "$screen_decision"; then
  printf '%s skip_combined_c4_confirmation reason=screen_not_promoted decision=%s\n' \
    "$(date --iso-8601=seconds)" "$screen_decision"
  exit 0
fi

qualification_manifest="$(sed -n 's/^manifest=//p' "$screen_decision")"
[[ -n "$qualification_manifest" && -f "$qualification_manifest" ]] || {
  echo "missing qualification manifest from $screen_decision" >&2
  exit 1
}
qualification_name="$(jq -r '.points[0].name' "$qualification_manifest")"
jq -e --arg name "$qualification_name" '
  .points | length == 1
  and .[0].name == $name
  and .[0].status == "provisional"
  and .[0].metadata.concurrency == 4
' "$qualification_manifest" >/dev/null

declare -a accepted_manifests=()
for stdout_path in $postflight_stdouts; do
  [[ -f "$stdout_path" ]] || {
    echo "missing base postflight stdout: $stdout_path" >&2
    exit 1
  }
  manifest="$(sed -n 's/^accepted_manifest=//p' "$stdout_path")"
  [[ -n "$manifest" && -f "$manifest" ]] || {
    echo "missing base accepted manifest from $stdout_path" >&2
    exit 1
  }
  [[ "$(printf '%s\n' "$manifest" | wc -l | tr -d ' ')" == 1 ]]
  jq -e '.points | length == 1 and .[0].status == "accepted"' \
    "$manifest" >/dev/null
  accepted_manifests+=("$manifest")
done
(( ${#accepted_manifests[@]} >= 2 )) || {
  echo "expected at least two base accepted manifests" >&2
  exit 3
}
for maxrun in 1 2; do
  matches=0
  for manifest in "${accepted_manifests[@]}"; do
    if jq -e --argjson maxrun "$maxrun" \
      '.points | length == 1 and .[0].metadata.max_running_requests == $maxrun' \
      "$manifest" >/dev/null; then
      ((matches += 1))
    fi
  done
  (( matches == 1 )) || {
    echo "expected one accepted maxrun-$maxrun manifest; found $matches" >&2
    exit 3
  }
done
base_candidate_manifests="${accepted_manifests[*]}"

env \
  TARGET_NODE="$target_node" \
  QUALIFICATION_MANIFEST="$qualification_manifest" \
  QUALIFICATION_DECISION="$screen_decision" \
  QUALIFICATION_NAME="$qualification_name" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  RESULT_LABEL=pr35872-pr37465-aiter5190-mtpverifyasm-c4 \
  DURATION=3600 \
  CONC=4 \
  MAX_RUNNING_REQUESTS_OVERRIDE=1 \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  SCHEDULER_RECV_INTERVAL_OVERRIDE=30 \
  PAGE_SIZE_OVERRIDE=16 \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  AITER_PATCH_PATH="$aiter_patch_path" \
  AITER_PATCH_SHA256="$aiter_patch_sha256" \
  EXPECTED_ROUTE_REGEX='EAGLE_TOPK1_BACKEND phase=draft_decode backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_2='EAGLE_TOPK1_BACKEND phase=draft_extend backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_3='module_mtp_verify_attn_asm|mtp_verify_attn_fwd_asm' \
  bash "$confirm"

postflight_job="$({
  env \
    TARGET_NODE="$target_node" \
    EXPECTED_CONFIRMATION_JOB_ID="$job_id" \
    CONFIRMATION_STDOUT="$confirmation_stdout" \
    BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
    sbatch --parsable --dependency="afterok:$job_id" --nodelist="$target_node" \
      "$postflight_resolver"
} )"
printf '%s submitted_combined_c4_postflight job_id=%s confirmation_job_id=%s\n' \
  "$(date --iso-8601=seconds)" "$postflight_job" "$job_id"
