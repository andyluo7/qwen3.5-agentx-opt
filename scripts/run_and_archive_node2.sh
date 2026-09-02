#!/usr/bin/env bash
set -u

if (( $# < 3 )); then
  echo "usage: $0 JOB_ID RESULT_NAME COMMAND [ARG ...]" >&2
  exit 2
fi

job_id="$1"
result_name="$2"
shift 2

target_node="${TARGET_NODE:-vultr-mi355x-2}"
bench_root="${BENCH_ROOT:-/data/enroot/andy_luo_3v7-qwen35-agentx-20260820}"
archive_root="${ARCHIVE_ROOT:-/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results}"
active_result_file="${ACTIVE_RESULT_FILE:-/shared/amdgpu/home/andy_luo_3v7/qwen35_node2_active_result.txt}"
trigger_job="${TRIGGER_JOB:-881}"
source_dir="$bench_root/results/$result_name"
archive_dir="$archive_root/$result_name"

if [[ ! "$result_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "unsafe result name: $result_name" >&2
  exit 2
fi
if squeue -a -h -j "$trigger_job" 2>/dev/null | grep -q .; then
  echo "job $trigger_job is present; refusing to start $result_name" >&2
  exit 75
fi
if ! squeue -h -j "$job_id" -o '%T' 2>/dev/null | grep -qx RUNNING; then
  echo "allocation $job_id is not running" >&2
  exit 75
fi

printf '%s\n' "$result_name" >"$active_result_file"
printf '%s starting result=%s command=' "$(date --iso-8601=seconds)" "$result_name"
printf '%q ' "$@"
printf '\n'

command_rc=0
"$@" || command_rc=$?
printf '%s command_rc=%s result=%s\n' \
  "$(date --iso-8601=seconds)" "$command_rc" "$result_name"

archive_rc=0
if squeue -h -j "$job_id" 2>/dev/null | grep -q .; then
  mkdir -p "$archive_dir"
  # Expansion in this payload is intentionally deferred to the compute node.
  # shellcheck disable=SC2016
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 --cpus-per-task=1 \
    --nodelist="$target_node" bash -lc '
      set -u
      src="$1"
      dst="$2"
      {
        date --iso-8601=seconds
        echo PORTS
        ss -ltnp 2>/dev/null | grep :8888 || true
        echo WORKLOAD_PROCESSES
        pgrep -af "[s]glang|[a]iperf|[q]wen3.5_fp4|[p]robe_aiter_custom_ar" || true
        echo KFD_USERS
        fuser /dev/kfd 2>/dev/null || true
        echo GPU_BUSY_VRAM
        for busy in /sys/class/drm/card*/device/gpu_busy_percent; do
          card=${busy%/device/gpu_busy_percent}
          printf "%s busy=" "${card##*/}"
          cat "$busy"
          printf "%s vram=" "${card##*/}"
          cat "$card/device/mem_info_vram_used"
        done
      } >"$src/teardown.txt"
      cd "$src" || exit 1
      find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
      cp -a "$src"/. "$dst"/
    ' bash "$source_dir" "$archive_dir" || archive_rc=$?
  if (( archive_rc == 0 )); then
    (
      cd "$archive_dir" || exit 1
      sha256sum -c SHA256SUMS
    ) >"$archive_dir/SHA256SUMS.verify" 2>&1 || archive_rc=$?
  fi
else
  archive_rc=75
  echo "allocation $job_id disappeared; job-$trigger_job watcher owns partial archival"
fi

if [[ -s "$active_result_file" ]] && [[ "$(head -n 1 "$active_result_file")" == "$result_name" ]]; then
  : >"$active_result_file"
fi

printf '%s archive_rc=%s archive=%s\n' \
  "$(date --iso-8601=seconds)" "$archive_rc" "$archive_dir"
if (( command_rc != 0 )); then
  exit "$command_rc"
fi
exit "$archive_rc"
