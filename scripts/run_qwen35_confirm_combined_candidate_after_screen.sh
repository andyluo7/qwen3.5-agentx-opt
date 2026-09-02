#!/usr/bin/env bash
#SBATCH --job-name=q35-combined-confirm
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=2
#SBATCH --time=01:45:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-combined-confirm-after-screen-%j.out

# Sustain a promoted combined-overlay screen only when the already accepted
# portfolio still misses the aggregate target. The successful
# confirmation submits its own independent eight-GPU postflight.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
target_node="${TARGET_NODE:?TARGET_NODE is required}"
screen_stdout="${SCREEN_STDOUT:?SCREEN_STDOUT is required}"
postflight_stdouts="${POSTFLIGHT_STDOUTS:?POSTFLIGHT_STDOUTS is required}"
prior_postflight_stdout="${PRIOR_POSTFLIGHT_STDOUT:-}"
candidate_conc="${CANDIDATE_CONC:?CANDIDATE_CONC is required}"
candidate_maxrun="${CANDIDATE_MAXRUN:?CANDIDATE_MAXRUN is required}"
candidate_page_size="${CANDIDATE_PAGE_SIZE:-16}"
candidate_scheduler_recv_interval="${CANDIDATE_SCHEDULER_RECV_INTERVAL:-30}"
result_label="${RESULT_LABEL:?RESULT_LABEL is required}"
qualification_gate="${QUALIFICATION_GATE:-advance_selected_candidates_to_sustained_confirmation=1}"
evaluator="$shared_root/evaluate_frontier_objective.py"
objective="$shared_root/frozen_frontier_objective_20260901.json"
confirm="$shared_root/run_qwen35_frontier_confirm_v4.sh"
postflight_resolver="$shared_root/run_qwen35_frontier_postflight_after_confirmation.sh"
patch_path="${PATCH_PATH:-$shared_root/sglang_pr35872_pr37465_combined_instrumented.patch}"
patch_sha256="${PATCH_SHA256:-d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3}"
aiter_patch_path="${AITER_PATCH_PATH:-$shared_root/aiter_pr5190_mtp_verify_attn_asm.patch}"
aiter_patch_sha256="${AITER_PATCH_SHA256:-10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09}"
confirmation_stdout="$shared_root/qwen35-combined-confirm-after-screen-${job_id}.out"

case "$candidate_conc" in
  1|4|6|7|8|12) ;;
  *)
    echo "CANDIDATE_CONC must be 1, 4, 6, 7, 8, or 12; got $candidate_conc" >&2
    exit 2
    ;;
esac
[[ "$candidate_maxrun" =~ ^[1-9][0-9]*$ ]] || {
  echo "CANDIDATE_MAXRUN must be a positive integer" >&2
  exit 2
}
[[ "$candidate_scheduler_recv_interval" =~ ^[1-9][0-9]*$ ]] || {
  echo "CANDIDATE_SCHEDULER_RECV_INTERVAL must be a positive integer" >&2
  exit 2
}
case "$candidate_page_size" in
  16|64) ;;
  *)
    echo "CANDIDATE_PAGE_SIZE must be 16 or 64; got $candidate_page_size" >&2
    exit 2
    ;;
esac
[[ "$result_label" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe RESULT_LABEL: $result_label" >&2
  exit 2
}
[[ "$qualification_gate" =~ ^[A-Za-z0-9_]+=[01]$ ]] || {
  echo "unsafe QUALIFICATION_GATE: $qualification_gate" >&2
  exit 2
}

for required in \
  "$screen_stdout" "$evaluator" "$objective" "$confirm" \
  "$postflight_resolver" "$patch_path" "$aiter_patch_path"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done

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
(( ${#accepted_manifests[@]} >= 4 )) || {
  echo "expected at least four base accepted manifests" >&2
  exit 3
}

# A preceding confirmation may have submitted an independent postflight that
# shares this node. If that postflight completed first, include its accepted
# manifest in the precheck so a later queued fallback does not spend another
# hour after the aggregate objective is already proved. A missing or failed
# prior postflight is intentionally ignored so this job remains the fallback.
if [[ -n "$prior_postflight_stdout" && -f "$prior_postflight_stdout" ]]; then
  prior_manifest="$(sed -n 's/^accepted_manifest=//p' "$prior_postflight_stdout")"
  if [[ -n "$prior_manifest" && -f "$prior_manifest" ]] \
    && [[ "$(printf '%s\n' "$prior_manifest" | wc -l | tr -d ' ')" == 1 ]] \
    && jq -e '.points | length == 1 and .[0].status == "accepted"' \
      "$prior_manifest" >/dev/null; then
    accepted_manifests+=("$prior_manifest")
    printf '%s included_prior_postflight manifest=%s stdout=%s\n' \
      "$(date --iso-8601=seconds)" "$prior_manifest" "$prior_postflight_stdout"
  else
    printf '%s ignored_prior_postflight reason=no_valid_accepted_manifest stdout=%s\n' \
      "$(date --iso-8601=seconds)" "$prior_postflight_stdout"
  fi
fi
for expected in "12 1" "12 2" "4 1" "8 1"; do
  read -r conc maxrun <<<"$expected"
  matches=0
  for manifest in "${accepted_manifests[@]}"; do
    if jq -e --argjson conc "$conc" --argjson maxrun "$maxrun" '
      .points | length == 1
      and .[0].metadata.concurrency == $conc
      and .[0].metadata.max_running_requests == $maxrun
    ' \
      "$manifest" >/dev/null; then
      ((matches += 1))
    fi
  done
  (( matches == 1 )) || {
    echo "expected one accepted C${conc}/maxrun-${maxrun} manifest; found $matches" >&2
    exit 3
  }
done
base_candidate_manifests="${accepted_manifests[*]}"

precheck="$shared_root/qwen35-combined-confirm-precheck-${job_id}.evaluation.json"
eval_args=(python3 "$evaluator" --objective "$objective")
for manifest in "${accepted_manifests[@]}"; do
  eval_args+=(--candidates "$manifest")
done
eval_args+=(--require-target --json --output "$precheck")
set +e
"${eval_args[@]}"
precheck_rc=$?
set -e
if (( precheck_rc == 0 )); then
  printf '%s skip_combined_confirmation reason=accepted_target_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$precheck"
  exit 0
fi
(( precheck_rc == 1 )) || {
  echo "accepted portfolio evaluation failed with rc=$precheck_rc" >&2
  exit "$precheck_rc"
}

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
  echo "could not recover screen decision from $screen_stdout" >&2
  exit 3
}
[[ "$(printf '%s\n' "$screen_decision" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous screen decision in $screen_stdout" >&2
  exit 3
}
[[ -f "$screen_decision" ]] || {
  echo "missing screen decision: $screen_decision" >&2
  exit 1
}
if ! grep -Fqx "$qualification_gate" "$screen_decision"; then
  printf '%s skip_combined_confirmation reason=screen_not_promoted decision=%s\n' \
    "$(date --iso-8601=seconds)" "$screen_decision"
  exit 0
fi

screen_manifest="$(sed -n 's/^manifest=//p' "$screen_decision")"
[[ -n "$screen_manifest" && -f "$screen_manifest" ]] || {
  echo "missing screen manifest from $screen_decision" >&2
  exit 1
}
[[ "$(printf '%s\n' "$screen_manifest" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous screen manifest in $screen_decision" >&2
  exit 3
}
promotion_candidates="$(sed -n 's/^promotion_candidates=//p' "$screen_decision")"
[[ "$(printf '%s\n' "$promotion_candidates" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous promotion candidate list in $screen_decision" >&2
  exit 3
}
matching_count="$(jq \
  --argjson conc "$candidate_conc" \
  --argjson maxrun "$candidate_maxrun" \
  --argjson page_size "$candidate_page_size" \
  --argjson scheduler_recv_interval "$candidate_scheduler_recv_interval" \
  '[.points[]
    | select(
        .status == "provisional"
        and .metadata.concurrency == $conc
        and .metadata.max_running_requests == $maxrun
        and .metadata.page_size == $page_size
        and .metadata.scheduler_recv_interval == $scheduler_recv_interval
      )] | length
' "$screen_manifest")"
(( matching_count == 1 )) || {
  echo "expected one C${candidate_conc}/maxrun-${candidate_maxrun}/page-${candidate_page_size}/recv-${candidate_scheduler_recv_interval} screen point; found $matching_count" >&2
  exit 3
}
qualification_name="$(jq -r \
  --argjson conc "$candidate_conc" \
  --argjson maxrun "$candidate_maxrun" \
  --argjson page_size "$candidate_page_size" \
  --argjson scheduler_recv_interval "$candidate_scheduler_recv_interval" '
  .points[]
  | select(
      .status == "provisional"
      and .metadata.concurrency == $conc
      and .metadata.max_running_requests == $maxrun
      and .metadata.page_size == $page_size
      and .metadata.scheduler_recv_interval == $scheduler_recv_interval
    )
  | .name
' "$screen_manifest")"
case ",$promotion_candidates," in
  *",$qualification_name,"*) ;;
  *)
    printf '%s skip_combined_confirmation reason=candidate_not_promoted candidate=%s decision=%s\n' \
      "$(date --iso-8601=seconds)" "$qualification_name" "$screen_decision"
    exit 0
    ;;
esac

qualification_manifest="$shared_root/qwen35-combined-qualification-${job_id}-c${candidate_conc}.candidates.json"
qualification_decision="$shared_root/qwen35-combined-qualification-${job_id}-c${candidate_conc}.decision.txt"
jq \
  --arg name "$qualification_name" '
  {schema_version: (.schema_version // 1), points: [.points[] | select(.name == $name)]}
' "$screen_manifest" >"$qualification_manifest"
jq -e '.points | length == 1 and .[0].status == "provisional"' \
  "$qualification_manifest" >/dev/null
{
  printf 'source_screen_decision=%s\n' "$screen_decision"
  printf 'source_screen_manifest=%s\n' "$screen_manifest"
  printf 'promotion_candidates=%s\n' "$promotion_candidates"
  printf '%s\n' "$qualification_gate"
  printf 'manifest=%s\n' "$qualification_manifest"
} >"$qualification_decision"

confirm_command=(bash)
if [[ "${TRACE_CONFIRM:-0}" == 1 ]]; then
  confirm_command=(bash -x)
fi

env \
  TARGET_NODE="$target_node" \
  QUALIFICATION_MANIFEST="$qualification_manifest" \
  QUALIFICATION_DECISION="$qualification_decision" \
  QUALIFICATION_NAME="$qualification_name" \
  QUALIFICATION_GATE="$qualification_gate" \
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
  RESULT_LABEL="$result_label" \
  DURATION=3600 \
  CONC="$candidate_conc" \
  MAX_RUNNING_REQUESTS_OVERRIDE="$candidate_maxrun" \
  CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  SCHEDULER_RECV_INTERVAL_OVERRIDE="$candidate_scheduler_recv_interval" \
  PAGE_SIZE_OVERRIDE="$candidate_page_size" \
  PATCH_PATH="$patch_path" \
  PATCH_SHA256="$patch_sha256" \
  AITER_PATCH_PATH="$aiter_patch_path" \
  AITER_PATCH_SHA256="$aiter_patch_sha256" \
  EXPECTED_ROUTE_REGEX='EAGLE_TOPK1_BACKEND phase=draft_decode backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_2='EAGLE_TOPK1_BACKEND phase=draft_extend backend=triton_split_argmax' \
  EXPECTED_ROUTE_REGEX_3='module_mtp_verify_attn_asm|mtp_verify_attn_fwd_asm' \
  "${confirm_command[@]}" "$confirm"

postflight_job="$(
  env \
    TARGET_NODE="$target_node" \
    EXPECTED_CONFIRMATION_JOB_ID="$job_id" \
    CONFIRMATION_STDOUT="$confirmation_stdout" \
    BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests" \
    sbatch --parsable --dependency="afterok:$job_id" --nodelist="$target_node" \
      "$postflight_resolver"
)"
printf '%s submitted_combined_postflight job_id=%s confirmation_job_id=%s\n' \
  "$(date --iso-8601=seconds)" "$postflight_job" "$job_id"
