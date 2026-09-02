#!/usr/bin/env bash
#SBATCH --job-name=q35-frontier-post-after
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=8
#SBATCH --time=00:10:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-frontier-postflight-after-confirm-%j.out

# Resolve a completed confirmation's timestamped outputs from its Slurm stdout,
# then run the independently allocated full-node postflight. Submit this job
# with an afterok dependency on the confirmation job.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
confirmation_stdout="${CONFIRMATION_STDOUT:?CONFIRMATION_STDOUT is required}"
expected_confirmation_job_id="${EXPECTED_CONFIRMATION_JOB_ID:-}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:-}"
postflight="$shared_root/run_qwen35_frontier_postflight_node2.sh"

for required in "$confirmation_stdout" "$postflight"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

if [[ -n "$expected_confirmation_job_id" ]]; then
  [[ "$expected_confirmation_job_id" =~ ^[0-9]+$ ]] || {
    echo "EXPECTED_CONFIRMATION_JOB_ID must be numeric" >&2
    exit 2
  }
  [[ "$confirmation_stdout" == *"-${expected_confirmation_job_id}.out" ]] || {
    echo "confirmation stdout is not bound to job $expected_confirmation_job_id" >&2
    exit 3
  }
fi

confirmation_decision="$(awk '
  /confirmation_done/ {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^decision=/) {
        sub(/^decision=/, "", $i)
        print $i
      }
    }
  }
' "$confirmation_stdout")"
[[ -n "$confirmation_decision" ]] || {
  echo "could not recover confirmation decision from $confirmation_stdout" >&2
  exit 3
}
[[ "$(printf '%s\n' "$confirmation_decision" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous confirmation decision in $confirmation_stdout" >&2
  exit 3
}
[[ -f "$confirmation_decision" ]] || {
  echo "missing confirmation decision: $confirmation_decision" >&2
  exit 1
}

confirmation_manifest="$(sed -n 's/^manifest=//p' "$confirmation_decision")"
confirmation_evaluation="$(sed -n 's/^evaluation=//p' "$confirmation_decision")"
for value in "$confirmation_manifest" "$confirmation_evaluation"; do
  [[ -n "$value" ]] || {
    echo "confirmation decision is missing a bound output" >&2
    exit 3
  }
  [[ "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" == 1 ]] || {
    echo "confirmation decision contains an ambiguous bound output" >&2
    exit 3
  }
  [[ -f "$value" ]] || {
    echo "missing confirmation output: $value" >&2
    exit 1
  }
done

grep -Fqx "manifest=$confirmation_manifest" "$confirmation_decision"
grep -Fqx "evaluation=$confirmation_evaluation" "$confirmation_decision"
grep -Fqx 'advance_to_full_node_postflight=1' "$confirmation_decision"

printf '%s resolved_confirmation stdout=%s decision=%s manifest=%s evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$confirmation_stdout" \
  "$confirmation_decision" "$confirmation_manifest" "$confirmation_evaluation"

env \
  TARGET_NODE="$target_node" \
  CONFIRMATION_MANIFEST="$confirmation_manifest" \
  CONFIRMATION_EVALUATION="$confirmation_evaluation" \
  CONFIRMATION_DECISION="$confirmation_decision" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  bash "$postflight"
