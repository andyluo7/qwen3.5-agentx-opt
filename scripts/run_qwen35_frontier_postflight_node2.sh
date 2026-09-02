#!/usr/bin/env bash
#SBATCH --job-name=q35-frontier-post
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-frontier-postflight-%j.out

# Independently verify that the complete node is clean after a successful
# sustained confirmation, then promote that one-point manifest to accepted.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
confirmation_manifest="${CONFIRMATION_MANIFEST:?CONFIRMATION_MANIFEST is required}"
confirmation_evaluation="${CONFIRMATION_EVALUATION:?CONFIRMATION_EVALUATION is required}"
confirmation_decision="${CONFIRMATION_DECISION:?CONFIRMATION_DECISION is required}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:-}"
fault_scan_since="${FAULT_SCAN_SINCE:-4 hours ago}"
output="$shared_root/qwen35-frontier-postflight-${job_id}.txt"
accepted_manifest="${ACCEPTED_MANIFEST_OUTPUT:-${confirmation_manifest%.candidates.json}.accepted.candidates.json}"
accepted_evaluation="${ACCEPTED_EVALUATION_OUTPUT:-${confirmation_manifest%.candidates.json}.accepted.evaluation.json}"
decision_path="${POSTFLIGHT_DECISION_OUTPUT:-${confirmation_manifest%.candidates.json}.postflight.decision.txt}"

[[ "${SLURM_GPUS_ON_NODE:-}" == 8 ]] || {
  echo "expected all eight GPUs; got SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}" >&2
  exit 2
}
for required in \
  "$evaluator" "$objective" "$confirmation_manifest" \
  "$confirmation_evaluation" "$confirmation_decision"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done
grep -Fqx 'advance_to_full_node_postflight=1' "$confirmation_decision" || {
  echo "confirmation did not authorize full-node postflight" >&2
  exit 3
}
grep -Fqx "manifest=$confirmation_manifest" "$confirmation_decision" || {
  echo "confirmation decision is not bound to $confirmation_manifest" >&2
  exit 3
}
grep -Fqx "evaluation=$confirmation_evaluation" "$confirmation_decision" || {
  echo "confirmation decision is not bound to $confirmation_evaluation" >&2
  exit 3
}
jq -e '.points | length == 1 and .[0].status == "provisional"' \
  "$confirmation_manifest" >/dev/null
candidate_name="$(jq -r '.points[0].name' "$confirmation_manifest")"
jq -e --arg name "$candidate_name" \
  'any(.selected[]; .selected_point == $name and .selected_status == "provisional")' \
  "$confirmation_evaluation" >/dev/null || {
  echo "confirmation candidate is not selected in its frontier evaluation" >&2
  exit 3
}
for manifest_path in $base_candidate_manifests; do
  [[ -f "$manifest_path" ]] || {
    echo "missing base candidate manifest: $manifest_path" >&2
    exit 1
  }
  jq -e 'all(.points[]; .status == "accepted")' "$manifest_path" >/dev/null || {
    echo "base candidate manifest contains non-accepted points: $manifest_path" >&2
    exit 3
  }
done

srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --cpus-per-task=1 --nodelist="$target_node" bash -s -- "$fault_scan_since" >"$output" <<'POSTFLIGHT'
set -euo pipefail
fault_scan_since="$1"
date --iso-8601=seconds
echo PORTS
if ss -ltnp 2>/dev/null | grep -E ':8888[[:space:]]'; then
  echo "unexpected port 8888 listener" >&2
  exit 1
fi
echo WORKLOAD_PROCESSES
if pgrep -af 'sglang|aiperf|launch_server|qwen35_pr2737' | grep -vE 'pgrep|postflight'; then
  echo "unexpected workload process" >&2
  exit 1
fi
echo KFD_USERS
if fuser /dev/kfd 2>/dev/null; then
  echo "unexpected /dev/kfd user" >&2
  exit 1
fi
echo GPU_BUSY_VRAM
gpu_count=0
for busy_file in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do
  [[ -r "$busy_file" ]] || continue
  card_dir="${busy_file%/device/gpu_busy_percent}"
  card="${card_dir##*/}"
  busy="$(<"$busy_file")"
  vram="$(<"$card_dir/device/mem_info_vram_used")"
  printf '%s busy=%s\n' "$card" "$busy"
  printf '%s vram=%s\n' "$card" "$vram"
  ((gpu_count += 1))
  (( busy == 0 )) || exit 1
  (( vram <= 400000000 )) || exit 1
done
(( gpu_count == 8 )) || {
  echo "expected eight GPU telemetry records; got $gpu_count" >&2
  exit 1
}
echo RECENT_GPU_FAULTS
faults="$(journalctl -k --since "$fault_scan_since" --no-pager 2>/dev/null \
  | grep -Ei 'amdgpu.*(fault|reset|ras)|xgmi.*error|page fault|GPU reset|HSA.*error' || true)"
if [[ -n "$faults" ]]; then
  printf '%s\n' "$faults"
  exit 1
fi
echo CLEAN
POSTFLIGHT

cat "$output"

jq \
  --arg postflight "$output" \
  --arg confirmation_decision "$confirmation_decision" '
  .points |= map(
    .status = "accepted"
    | .metadata.evidence_stage = "accepted_after_sustained_confirmation_and_postflight"
    | .metadata.postflight_artifact = $postflight
    | .metadata.confirmation_decision = $confirmation_decision
  )
' "$confirmation_manifest" >"$accepted_manifest"

eval_args=(python3 "$evaluator" --objective "$objective")
for manifest_path in $base_candidate_manifests; do
  eval_args+=(--candidates "$manifest_path")
done
eval_args+=(--candidates "$accepted_manifest" --json --output "$accepted_evaluation")
"${eval_args[@]}"

selected_anchor_count="$(jq --arg name "$candidate_name" \
  '[.selected[] | select(.selected_point == $name and .selected_status == "accepted")] | length' \
  "$accepted_evaluation")"
(( selected_anchor_count > 0 )) || {
  echo "accepted candidate no longer advances the combined frontier" >&2
  exit 4
}

new_mean="$(jq -r '.new_mean' "$accepted_evaluation")"
relative_gain_pct="$(jq -r '.relative_mean_gain * 100' "$accepted_evaluation")"
remaining_mean_gain="$(jq -r '.remaining_mean_gain' "$accepted_evaluation")"
objective_achieved="$(jq -r '.objective_achieved | if . then 1 else 0 end' "$accepted_evaluation")"
{
  printf 'candidate_name=%s\n' "$candidate_name"
  printf 'accepted_selected_anchor_count=%s\n' "$selected_anchor_count"
  printf 'accepted_frontier_mean=%s\n' "$new_mean"
  printf 'accepted_relative_mean_gain_pct=%s\n' "$relative_gain_pct"
  printf 'remaining_mean_gain=%s\n' "$remaining_mean_gain"
  printf 'objective_achieved=%s\n' "$objective_achieved"
  printf 'postflight=%s\naccepted_manifest=%s\naccepted_evaluation=%s\n' \
    "$output" "$accepted_manifest" "$accepted_evaluation"
} | tee "$decision_path"
