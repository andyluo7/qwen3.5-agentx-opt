#!/usr/bin/env bash
set -euo pipefail

job_id="${1:?usage: $0 SLURM_JOB_ID}"
root="${BENCH_ROOT:-/data/enroot/andy_luo_3v7-qwen35-agentx-20260820}"
target_node="${TARGET_NODE:-vultr-mi355x-2}"
result_name="${RESULT_NAME:?RESULT_NAME is required}"
result_dir="$root/results/$result_name"
image="$root/containers/lmsysorg_sglang-rocm_v0.5.18-rocm720-mi35x-20260829.sqsh"
image_provenance="$image.provenance.txt"
repo="${INFERENCEX_REPO:-/shared/amdgpu/home/andy_luo_3v7/InferenceX-qwen35-875cd72}"
hf_cache="$root/cache/hf-hub"
aiperf_cache="$root/cache/aiperf-mmap"

inferencex_commit=875cd72b3c1b67a4d7fde75cf5ae1e028dd95fb7
aiperf_commit=754356e9a39acc6cc6afb242d123bb57c3fb6f75
sglang_commit=cdbfe90b4a6c728e03e6520862d792501b3a97bb
aiter_commit=c16d44b93a528b2a4bfd6d8d3409116d465872a9
recipe_fingerprint=ecf94fe385859291
model_repo=amd/Qwen3.5-397B-A17B-MXFP4
model_revision=edf0958bc3734dda98a9d191cc7a0a83c4f42821
model_cache_key="models--${model_repo//\//--}"
model_host_path="$hf_cache/$model_cache_key/snapshots/$model_revision"
model_container_path="/mnt/hf_hub_cache/$model_cache_key/snapshots/$model_revision"

duration="${DURATION:-120}"
conc="${CONC:-12}"
max_running_requests="${MAX_RUNNING_REQUESTS_OVERRIDE:-24}"
cuda_graph_max_bs="${CUDA_GRAPH_MAX_BS_OVERRIDE:-24}"
port="${PORT:-8888}"
result_filename="${RESULT_FILENAME_OVERRIDE:-qwen35_pr2737_c12_exact_${result_name}}"
aiperf_runtime_dir="/tmp/inferencex-agentic-pr2737-${SLURM_JOB_ID:-manual}-${result_name}"
container_path=/root/.cargo/bin:/opt/venv/bin:/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin

[[ "$result_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "unsafe result name: $result_name" >&2
  exit 2
}
[[ "$conc" == 12 ]] || {
  echo "this runner is intentionally restricted to C12" >&2
  exit 2
}
for value in "$duration" "$max_running_requests" "$cuda_graph_max_bs" "$port"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "duration, max-running, graph size, and port must be positive integers" >&2
    exit 2
  }
done

for required in \
  "$image" \
  "$image_provenance" \
  "$repo/INFERENCEX_COMMIT.txt" \
  "$repo/AIPERF_COMMIT.txt" \
  "$repo/benchmarks/benchmark_lib.sh" \
  "$repo/benchmarks/single_node/agentic/qwen3.5_fp4_mi355x_sglang_mtp.sh" \
  "$model_host_path/config.json"; do
  srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --nodelist="$target_node" test -f "$required"
done

srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --cpus-per-task=1 --nodelist="$target_node" bash -s -- \
  "$result_dir" "$image" "$image_provenance" "$model_host_path" \
  "$repo" "$inferencex_commit" "$recipe_fingerprint" \
  "$aiperf_commit" "$sglang_commit" "$aiter_commit" \
  "$duration" "$conc" "$max_running_requests" "$cuda_graph_max_bs" <<'PREP'
set -euo pipefail
result_dir="$1"
image="$2"
image_provenance="$3"
model_host_path="$4"
repo="$5"
inferencex_commit="$6"
recipe_fingerprint="$7"
aiperf_commit="$8"
sglang_commit="$9"
aiter_commit="${10}"
duration="${11}"
conc="${12}"
max_running_requests="${13}"
cuda_graph_max_bs="${14}"
mkdir -p "$result_dir"
test "$(<"$repo/INFERENCEX_COMMIT.txt")" = "$inferencex_commit"
test "$(<"$repo/AIPERF_COMMIT.txt")" = "$aiperf_commit"
test -f "$repo/utils/aiperf/pyproject.toml"
cp "$image_provenance" "$result_dir/image.provenance.txt"
cp "$repo/benchmarks/single_node/agentic/qwen3.5_fp4_mi355x_sglang_mtp.sh" \
  "$result_dir/official_recipe_with_env_override.sh"
cp "$repo/benchmarks/benchmark_lib.sh" "$result_dir/benchmark_lib.sh"
sha256sum "$image" > "$result_dir/image.sha256"
sha256sum "$model_host_path/config.json" > "$result_dir/model_config.sha256"
sha256sum \
  "$repo/benchmarks/single_node/agentic/qwen3.5_fp4_mi355x_sglang_mtp.sh" \
  "$repo/benchmarks/benchmark_lib.sh" > "$result_dir/source_files.sha256"
{
  printf 'inferencex_commit=%s\n' "$inferencex_commit"
  printf 'aiperf_commit=%s\n' "$aiperf_commit"
  printf 'sglang_commit=%s\n' "$sglang_commit"
  printf 'aiter_commit=%s\n' "$aiter_commit"
  printf 'recipe_fingerprint=%s\n' "$recipe_fingerprint"
  printf 'duration=%s\n' "$duration"
  printf 'concurrency=%s\n' "$conc"
  printf 'max_running_requests=%s\n' "$max_running_requests"
  printf 'cuda_graph_max_bs=%s\n' "$cuda_graph_max_bs"
} > "$result_dir/run_identity.txt"
PREP

container_mounts="$repo:/workspace,$hf_cache:/mnt/hf_hub_cache,$aiperf_cache:/aiperf_mmap_cache,$result_dir:/results"

srun --jobid="$job_id" --overlap --account=r7n --nodes=1 --ntasks=1 \
  --nodelist="$target_node" --gpus=2 --cpus-per-task=128 \
  --container-image="$image" \
  --container-mounts="$container_mounts" \
  --container-writable \
  --container-workdir=/workspace \
  --container-remap-root \
  --no-container-entrypoint \
  --export=ALL,AIPERF_DATASET_MMAP_CACHE_DIR=/aiperf_mmap_cache \
  bash -o pipefail -c "
    env PATH=$container_path LD_LIBRARY_PATH=/opt/rocm/lib \
      bash -c '
        set -e
        printf \"python=\"; command -v python3
        python3 -V
        printf \"slurm_gpus_on_node=%s\\n\" \"\${SLURM_GPUS_ON_NODE:-unset}\"
        printf \"slurm_step_gpus=%s\\n\" \"\${SLURM_STEP_GPUS:-unset}\"
        printf \"rocr_visible_devices=%s\\n\" \"\${ROCR_VISIBLE_DEVICES:-unset}\"
        visible_gpu_count=\$(amd-smi list | grep -c \"^GPU:\")
        printf \"amd_smi_visible_gpu_count=%s\\n\" \"\$visible_gpu_count\"
        test \"\$visible_gpu_count\" -eq 2
        printf \"sglang_commit=\"; git -C /sgl-workspace/sglang rev-parse HEAD
        printf \"aiter_commit=\"; git -C /sgl-workspace/aiter rev-parse HEAD
        python3 -c \"import sglang, aiter, torch; print(\\\"sglang_path=\\\" + sglang.__file__); print(\\\"aiter_path=\\\" + aiter.__file__); print(\\\"torch_version=\\\" + torch.__version__)\"
      ' > /results/container_runtime.txt
    grep -qx 'sglang_commit=$sglang_commit' /results/container_runtime.txt
    grep -qx 'aiter_commit=$aiter_commit' /results/container_runtime.txt
    env \
      PATH=$container_path \
      LD_LIBRARY_PATH=/opt/rocm/lib \
      DEBIAN_FRONTEND=noninteractive \
      BUILD_VLLM=0 \
      BUILD_TRITON=1 \
      BUILD_LLVM=0 \
      BUILD_AITER_ALL=1 \
      BUILD_MOONCAKE=1 \
      AITER_COMMIT_DEFAULT=$aiter_commit \
      GPU_ARCH=gfx950-rocm720 \
      GPU_ARCH_LIST=gfx950 \
      PYTORCH_ROCM_ARCH='gfx942;gfx950' \
      AITER_COMMIT=$aiter_commit \
      SETUPTOOLS_SCM_PRETEND_VERSION= \
      AITER_USE_SYSTEM_TRITON=1 \
      CARGO_BUILD_JOBS=4 \
      LIBGL_ALWAYS_INDIRECT=1 \
      SGLANG_DISABLE_CUDNN_CHECK=1 \
      HIP_FORCE_DEV_KERNARG=1 \
      HSA_NO_SCRATCH_RECLAIM=1 \
      SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1 \
      SGLANG_INT4_WEIGHT=0 \
      SGLANG_MOE_PADDING=1 \
      SGLANG_ROCM_DISABLE_LINEARQUANT=0 \
      SGLANG_ROCM_FUSED_DECODE_MLA=1 \
      SGLANG_SET_CPU_AFFINITY=1 \
      SGLANG_USE_AITER=1 \
      SGLANG_USE_ROCM700A=1 \
      NCCL_MIN_NCHANNELS=112 \
      ROCM_QUICK_REDUCE_QUANTIZATION=INT8 \
      TORCHINDUCTOR_MAX_AUTOTUNE=1 \
      TORCHINDUCTOR_MAX_AUTOTUNE_POINTWISE=1 \
      HF_HUB_CACHE=/mnt/hf_hub_cache \
      MODEL=$model_repo \
      MODEL_PATH=$model_container_path \
      MODEL_PREFIX=qwen3.5 \
      IMAGE=lmsysorg/sglang-rocm:v0.5.18-rocm720-mi35x-20260829 \
      FRAMEWORK=sglang \
      PRECISION=fp4 \
      TP=2 \
      PP_SIZE=1 \
      DCP_SIZE=1 \
      PCP_SIZE=1 \
      EP_SIZE=1 \
      DP_ATTENTION=false \
      CONC=$conc \
      SPEC_DECODING=mtp \
      DISAGG=false \
      IS_MULTINODE=false \
      SCENARIO_TYPE=agentic-coding \
      IS_AGENTIC=1 \
      KV_OFFLOADING=none \
      TOTAL_CPU_DRAM_GB=2476 \
      DURATION=$duration \
      PORT=$port \
      RUN_EVAL=false \
      EVAL_ONLY=false \
      AIPERF_EXPERIMENTAL_FAST=0 \
      AIPERF_FAILED_REQUEST_THRESHOLD=0.10 \
      ENABLE_AGENTX_POWER=1 \
      REQUIRE_POWER=1 \
      RUNNER_TYPE=cluster:mi355x-amds \
      RUNNER_NAME=$target_node \
      RECIPE_FINGERPRINT=$recipe_fingerprint \
      RESULT_FILENAME=$result_filename \
      RESULT_DIR=/results \
      AGENTIC_OUTPUT_DIR=/results \
      AIPERF_RUNTIME_DIR=$aiperf_runtime_dir \
      PYTHONDONTWRITEBYTECODE=1 \
      PYTHONPYCACHEPREFIX=/tmp/inferencex-pycache-pr2737-${SLURM_JOB_ID:-manual} \
      MAX_RUNNING_REQUESTS_OVERRIDE=$max_running_requests \
      CUDA_GRAPH_MAX_BS_OVERRIDE=$cuda_graph_max_bs \
      bash benchmarks/single_node/agentic/qwen3.5_fp4_mi355x_sglang_mtp.sh \
      2>&1 | tee /results/driver.log
  "
