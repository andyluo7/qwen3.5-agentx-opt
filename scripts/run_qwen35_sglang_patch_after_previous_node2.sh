#!/usr/bin/env bash
#SBATCH --job-name=q35-next-sgl-patch
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
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-next-sglang-patch-%j.out

# Chain one isolated source-patch bracket after another. A predecessor's
# candidate manifest is added to the portfolio, but its source patch is never
# stacked into the next candidate. Stop screening once the provisional
# portfolio has numerically reached the target; accepted status still requires
# sustained confirmation and postflight.
set -euo pipefail

shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
previous_stdout="${PREVIOUS_STDOUT:?PREVIOUS_STDOUT is required}"
previous_patch_label="${PREVIOUS_PATCH_LABEL:?PREVIOUS_PATCH_LABEL is required}"
ancestor_patch_chain="${ANCESTOR_PATCH_CHAIN:-}"
base_candidate_manifests="${BASE_CANDIDATE_MANIFESTS:?BASE_CANDIDATE_MANIFESTS is required}"
patch_path="${PATCH_PATH:?PATCH_PATH is required}"
patch_sha256="${PATCH_SHA256:?PATCH_SHA256 is required}"
patch_label="${PATCH_LABEL:?PATCH_LABEL is required}"
expected_route_regex="${EXPECTED_ROUTE_REGEX:?EXPECTED_ROUTE_REGEX is required}"
expected_route_regex_2="${EXPECTED_ROUTE_REGEX_2:-}"
duration="${DURATION:-900}"
conc="${CONC:-4}"
maxrun="${MAX_RUNNING_REQUESTS_OVERRIDE:-1}"
graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"

patch_wrapper="$shared_root/run_qwen35_sglang_patch_bracket_node2.sh"
point_launcher="$shared_root/run_qwen35_pr2737_lowconc_exact_point_node2.sh"

for required in \
  "$previous_stdout" "$patch_wrapper" "$point_launcher" "$patch_path"; do
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

if grep -Fq 'reason=provisional_target_numerically_met' "$previous_stdout"; then
  printf '%s skip_sglang_patch patch_label=%s reason=provisional_target_numerically_met upstream=%s\n' \
    "$(date --iso-8601=seconds)" "$patch_label" "$previous_stdout"
  exit 0
fi

for entry in $ancestor_patch_chain; do
  ancestor_stdout="${entry%%|*}"
  ancestor_label="${entry#*|}"
  [[ "$ancestor_stdout" != "$ancestor_label" ]] || {
    echo "invalid ANCESTOR_PATCH_CHAIN entry: $entry" >&2
    exit 2
  }
  [[ -f "$ancestor_stdout" ]] || {
    echo "missing ancestor stdout: $ancestor_stdout" >&2
    exit 1
  }
  if grep -Fq 'reason=provisional_target_numerically_met' "$ancestor_stdout"; then
    printf '%s skip_sglang_patch patch_label=%s reason=provisional_target_numerically_met upstream=%s\n' \
      "$(date --iso-8601=seconds)" "$patch_label" "$ancestor_stdout"
    exit 0
  fi
  ancestor_summary="$(awk -v expected="$ancestor_label" '
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
  ' "$ancestor_stdout")"
  [[ -n "$ancestor_summary" && "$ancestor_summary" == *.tsv ]] || {
    echo "could not recover $ancestor_label summary from $ancestor_stdout" >&2
    exit 3
  }
  [[ "$(printf '%s\n' "$ancestor_summary" | wc -l | tr -d ' ')" == 1 ]] || {
    echo "ambiguous $ancestor_label summary in $ancestor_stdout" >&2
    exit 3
  }
  ancestor_prefix="${ancestor_summary%.tsv}"
  ancestor_manifest="$ancestor_prefix.candidates.json"
  ancestor_evaluation="$ancestor_prefix.evaluation.json"
  ancestor_decision="$ancestor_prefix.decision.txt"
  for required in \
    "$ancestor_manifest" "$ancestor_evaluation" "$ancestor_decision"; do
    [[ -f "$required" ]] || {
      echo "missing ancestor output: $required" >&2
      exit 1
    }
  done
  grep -Fqx "manifest=$ancestor_manifest" "$ancestor_decision" || {
    echo "$ancestor_label decision is not bound to $ancestor_manifest" >&2
    exit 3
  }
  grep -Fqx "evaluation=$ancestor_evaluation" "$ancestor_decision" || {
    echo "$ancestor_label decision is not bound to $ancestor_evaluation" >&2
    exit 3
  }
  base_candidate_manifests+=" $ancestor_manifest"
done

previous_summary="$(awk -v expected="$previous_patch_label" '
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
' "$previous_stdout")"
[[ -n "$previous_summary" && "$previous_summary" == *.tsv ]] || {
  echo "could not recover $previous_patch_label summary from $previous_stdout" >&2
  exit 3
}
[[ "$(printf '%s\n' "$previous_summary" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "ambiguous $previous_patch_label summary in $previous_stdout" >&2
  exit 3
}

previous_prefix="${previous_summary%.tsv}"
previous_manifest="$previous_prefix.candidates.json"
previous_evaluation="$previous_prefix.evaluation.json"
previous_decision="$previous_prefix.decision.txt"
for required in \
  "$previous_manifest" "$previous_evaluation" "$previous_decision"; do
  [[ -f "$required" ]] || {
    echo "missing predecessor output: $required" >&2
    exit 1
  }
done
grep -Fqx "manifest=$previous_manifest" "$previous_decision" || {
  echo "predecessor decision is not bound to $previous_manifest" >&2
  exit 3
}
grep -Fqx "evaluation=$previous_evaluation" "$previous_decision" || {
  echo "predecessor decision is not bound to $previous_evaluation" >&2
  exit 3
}

if [[ "$(jq -r '.target_numerically_met' "$previous_evaluation")" == true ]]; then
  printf '%s skip_sglang_patch patch_label=%s reason=provisional_target_numerically_met evaluation=%s\n' \
    "$(date --iso-8601=seconds)" "$patch_label" "$previous_evaluation"
  exit 0
fi

actual_patch_sha256="$(sha256sum "$patch_path" | awk '{print $1}')"
[[ "$actual_patch_sha256" == "$patch_sha256" ]] || {
  echo "patch checksum mismatch: expected $patch_sha256 got $actual_patch_sha256" >&2
  exit 2
}

base_candidate_manifests+=" $previous_manifest"
printf '%s starting_sglang_patch patch_label=%s concurrency=%s previous_evaluation=%s\n' \
  "$(date --iso-8601=seconds)" "$patch_label" "$conc" "$previous_evaluation"

run_env=(
  POINT_SCRIPT="$point_launcher"
  BASE_CANDIDATE_MANIFESTS="$base_candidate_manifests"
  PATCH_PATH="$patch_path"
  PATCH_SHA256="$patch_sha256"
  PATCH_LABEL="$patch_label"
  EXPECTED_ROUTE_REGEX="$expected_route_regex"
  DURATION="$duration"
  CONC="$conc"
  MAX_RUNNING_REQUESTS_OVERRIDE="$maxrun"
  CUDA_GRAPH_MAX_BS_OVERRIDE="$graph_max_bs"
)
if [[ -n "$expected_route_regex_2" ]]; then
  run_env+=(EXPECTED_ROUTE_REGEX_2="$expected_route_regex_2")
fi
env "${run_env[@]}" bash "$patch_wrapper"
