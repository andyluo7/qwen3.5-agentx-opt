#!/usr/bin/env bash
#SBATCH --job-name=q35-mtp-asm-smoke
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=00:45:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr37465-pr5190-smoke-%j.out

# Validate the exact AITER #5190 binary patch and SGLang #37465 integration on
# a clean MI355X before allocating a full AgentX A/B bracket.
set -euo pipefail

job_id="${SLURM_JOB_ID:?run this script with sbatch}"
shared_root="${SHARED_ROOT:-/shared/amdgpu/home/andy_luo_3v7}"
bench_root="${BENCH_ROOT:-/data/enroot/andy_luo_3v7-qwen35-agentx-20260820}"
target_node="${TARGET_NODE:-vultr-mi355x-1}"
image="$bench_root/containers/lmsysorg_sglang-rocm_v0.5.18-rocm720-mi35x-20260829.sqsh"
aiter_patch="$shared_root/aiter_pr5190_mtp_verify_attn_asm.patch"
sglang_patch="$shared_root/sglang_pr37465_aiter_mtp_verify_attn.patch"
aiter_patch_sha256=10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09
sglang_patch_sha256=e9124715a64b6baec67194524c47ee9451d2634886715476e3fc29bfb680b5b7
sglang_commit=cdbfe90b4a6c728e03e6520862d792501b3a97bb
aiter_commit=c16d44b93a528b2a4bfd6d8d3409116d465872a9
output="$shared_root/qwen35-pr37465-pr5190-smoke-$job_id"

for required in "$image" "$aiter_patch" "$sglang_patch"; do
  [[ -f "$required" ]] || {
    echo "missing required file: $required" >&2
    exit 1
  }
done
[[ "$(sha256sum "$aiter_patch" | awk '{print $1}')" == "$aiter_patch_sha256" ]]
[[ "$(sha256sum "$sglang_patch" | awk '{print $1}')" == "$sglang_patch_sha256" ]]

wait_clean() {
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --nodelist="$target_node" bash -s <<'PREFLIGHT'
set -euo pipefail
for attempt in $(seq 1 60); do
  dirty=0
  ss -ltn 2>/dev/null | grep -q ':8888 ' && dirty=1
  fuser /dev/kfd >/tmp/qwen35-pr37465-pr5190-kfd-users 2>/dev/null && dirty=1
  card_count=0
  for busy_file in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do
    [[ -r "$busy_file" ]] || continue
    ((card_count += 1))
    card_dir="${busy_file%/device/gpu_busy_percent}"
    busy="$(<"$busy_file")"
    vram="$(<"$card_dir/device/mem_info_vram_used")"
    if (( busy != 0 || vram > 400000000 )); then
      dirty=1
    fi
  done
  if (( dirty == 0 && card_count == 8 )); then
    exit 0
  fi
  (( attempt < 60 )) && sleep 5
done
echo "node did not become clean within 300 seconds" >&2
exit 75
PREFLIGHT
}

wait_clean
srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --cpus-per-task=1 --nodelist="$target_node" mkdir -p "$output"
srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --cpus-per-task=1 --nodelist="$target_node" cp \
  "$aiter_patch" "$sglang_patch" "$output/"

srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --nodelist="$target_node" --gpus=1 --cpus-per-task=64 \
  --container-image="$image" \
  --container-mounts="$aiter_patch:/aiter_patch.diff:ro,$sglang_patch:/sglang_patch.diff:ro,$output:/results" \
  --container-writable \
  --container-workdir=/sgl-workspace/aiter \
  --container-remap-root \
  --no-container-entrypoint \
  bash -o pipefail -s 2>&1 <<CONTAINER | tee "$output/smoke.log"
set -euo pipefail
test "\$(git -C /sgl-workspace/sglang rev-parse HEAD)" = "$sglang_commit"
test "\$(git -C /sgl-workspace/aiter rev-parse HEAD)" = "$aiter_commit"
test "\$(sha256sum /aiter_patch.diff | awk '{print \$1}')" = "$aiter_patch_sha256"
test "\$(sha256sum /sglang_patch.diff | awk '{print \$1}')" = "$sglang_patch_sha256"
git -C /sgl-workspace/aiter apply --check /aiter_patch.diff
git -C /sgl-workspace/aiter apply /aiter_patch.diff
git -C /sgl-workspace/sglang apply --check /sglang_patch.diff
git -C /sgl-workspace/sglang apply /sglang_patch.diff
git -C /sgl-workspace/aiter diff --check
git -C /sgl-workspace/sglang diff --check
git -C /sgl-workspace/aiter diff --binary > /results/aiter_worktree.patch
git -C /sgl-workspace/sglang diff --binary > /results/sglang_worktree.patch
export PATH=/root/.cargo/bin:/opt/venv/bin:/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin
export LD_LIBRARY_PATH=/opt/rocm/lib
export GPU_ARCH_LIST=gfx950
export PYTORCH_ROCM_ARCH=gfx950
export AITER_USE_SYSTEM_TRITON=1
export HIP_FORCE_DEV_KERNARG=1
python3 -m py_compile \
  /sgl-workspace/sglang/python/sglang/kernels/ops/attention/unified_attention_3d_mtp.py \
  /sgl-workspace/sglang/python/sglang/srt/layers/attention/aiter_backend.py
python3 - <<'PY'
import aiter
from sglang.kernels.ops.attention.unified_attention_3d_mtp import asm_verify_attn_enabled

assert hasattr(aiter, "mtp_verify_attn_fwd_asm")
assert asm_verify_attn_enabled()
print("SGLANG_ASM_VERIFY_ATTN_IMPORT_OK enabled=1")
PY
python3 op_tests/test_mtp_verify_attn_asm.py --perf
printf 'PR37465_PR5190_SMOKE_OK\n'
CONTAINER

grep -Fq 'SGLANG_ASM_VERIFY_ATTN_IMPORT_OK enabled=1' "$output/smoke.log"
grep -Fq 'PR37465_PR5190_SMOKE_OK' "$output/smoke.log"
grep -Fq 'module_mtp_verify_attn_asm' "$output/smoke.log"
wait_clean
srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --cpus-per-task=1 --nodelist="$target_node" bash -s -- "$output" <<'POSTFLIGHT'
set -euo pipefail
output="$1"
{
  printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
  for busy_file in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do
    [[ -r "$busy_file" ]] || continue
    card_dir="${busy_file%/device/gpu_busy_percent}"
    printf '%s busy=%s vram=%s\n' "${card_dir##*/}" \
      "$(<"$busy_file")" "$(<"$card_dir/device/mem_info_vram_used")"
  done
  if fuser /dev/kfd 2>/dev/null; then
    echo 'kfd_users_present=1'
    exit 1
  fi
  echo 'kfd_users_present=0'
} | tee "$output/postflight.txt"
sha256sum "$output"/* > "$output/SHA256SUMS"
sha256sum -c "$output/SHA256SUMS" > "$output/SHA256SUMS.verify"
POSTFLIGHT

printf '%s smoke_done output=%s\n' "$(date --iso-8601=seconds)" "$output"
