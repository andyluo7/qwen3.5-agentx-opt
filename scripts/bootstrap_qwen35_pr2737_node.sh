#!/usr/bin/env bash
#SBATCH --job-name=q35-pr2737-bootstrap
#SBATCH --account=r7n
#SBATCH --partition=256C8G1H_MI355X_Ubuntu24
#SBATCH --reservation=aac17_vultr-mi355x-1_vultr-mi355x-2_vultr-mi355x-3_vultr-mi355x-4_vultr-mi355x-5_vultr-mi355x-6_reservation
#SBATCH --nodelist=vultr-mi355x-5
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=03:00:00
#SBATCH --output=/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-bootstrap-%j.out

# Bootstrap the exact node-local image and model cache used by the frozen
# Qwen3.5 AgentX frontier objective. This job intentionally requests no GPUs so
# an idle node can be prepared without consuming accelerator capacity.
set -euo pipefail

root="${BENCH_ROOT:-/data/enroot/andy_luo_3v7-qwen35-agentx-20260820}"
tag=v0.5.18-rocm720-mi35x-20260829
image="$root/containers/lmsysorg_sglang-rocm_${tag}.sqsh"
provenance="$image.provenance.txt"
expected_index_digest=sha256:815b036c237604c4ecc9d3387bd76f71814c3c804fe5f528039c10e4743b2e9f
model_repo=amd/Qwen3.5-397B-A17B-MXFP4
model_revision=edf0958bc3734dda98a9d191cc7a0a83c4f42821
model_cache="$root/cache/hf-hub"
model_snapshot="$model_cache/models--amd--Qwen3.5-397B-A17B-MXFP4/snapshots/$model_revision"
expected_model_config_sha256=f3f18d5b47ac8d980ecb8dfc182a4a545de65913bfd007c5facd0f604c23e0b0
expected_model_shards=94
job_id="${SLURM_JOB_ID:-manual-$(date +%Y%m%dT%H%M%S)}"
bootstrap_root="$root/bootstrap"
venv="$bootstrap_root/hf-venv"
sandbox="$root/tmp/qwen35-v0518-singularity-$job_id"
partial="$image.partial.$job_id"
singularity_cache="$root/cache/singularity"
singularity_tmp="$root/tmp/singularity-tmp-$job_id"

mkdir -p \
  "$root/containers" "$root/cache/aiperf-mmap" "$model_cache" \
  "$root/results" "$root/tmp" "$bootstrap_root"

verify_model() {
  [[ -f "$model_snapshot/config.json" ]] || return 1
  [[ "$(sha256sum "$model_snapshot/config.json" | awk '{print $1}')" \
    == "$expected_model_config_sha256" ]] || return 1
  [[ "$(find -L "$model_snapshot" -maxdepth 1 -type f \
    -name 'model.safetensors-*-of-00094.safetensors' | awk 'END {print NR}')" \
    == "$expected_model_shards" ]] || return 1
  [[ -f "$model_snapshot/model.safetensors.index.json" ]] || return 1
  [[ -z "$(find -L "$model_snapshot" -maxdepth 1 -type l -print -quit)" ]]
}

verify_image() {
  [[ -s "$image" && -f "$provenance" ]] || return 1
  grep -Fqx "source_index_digest=$expected_index_digest" "$provenance" || return 1
  recorded_sha256="$(sed -n 's/^sqsh_sha256=//p' "$provenance")"
  [[ "$recorded_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$(sha256sum "$image" | awk '{print $1}')" == "$recorded_sha256" ]]
}

download_model() {
  if verify_model; then
    printf '%s model already verified: %s\n' \
      "$(date --iso-8601=seconds)" "$model_snapshot"
    return
  fi

  if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv"
  fi
  "$venv/bin/python" -m pip install --disable-pip-version-check --upgrade \
    'huggingface_hub[hf_xet]>=0.34,<2'
  HF_HUB_ENABLE_HF_TRANSFER=0 "$venv/bin/python" - \
    "$model_cache" "$model_repo" "$model_revision" <<'PY'
import sys
from huggingface_hub import snapshot_download

cache_dir, repo_id, revision = sys.argv[1:]
path = snapshot_download(
    repo_id=repo_id,
    revision=revision,
    cache_dir=cache_dir,
    max_workers=16,
)
print(path, flush=True)
PY
  verify_model
}

build_image() {
  if verify_image; then
    printf '%s image already verified: %s\n' \
      "$(date --iso-8601=seconds)" "$image"
    return
  fi
  if [[ -e "$image" || -e "$provenance" ]]; then
    echo "refusing to overwrite an unverified image or provenance record" >&2
    return 2
  fi

  mkdir -p "$singularity_cache" "$singularity_tmp"
  test ! -e "$sandbox"
  test ! -e "$partial"
  export SINGULARITY_CACHEDIR="$singularity_cache"
  export SINGULARITY_TMPDIR="$singularity_tmp"
  export APPTAINER_CACHEDIR="$singularity_cache"
  export APPTAINER_TMPDIR="$singularity_tmp"

  token="$({ curl -fsSL 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:lmsysorg/sglang-rocm:pull'; } | jq -r .token)"
  resolved_index_digest="$({
    curl -fsSI \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      "https://registry-1.docker.io/v2/lmsysorg/sglang-rocm/manifests/$tag"
  } | awk 'BEGIN { IGNORECASE=1 } /^docker-content-digest:/ { gsub("\\r", "", $2); print $2 }' | tail -n 1)"
  [[ "$resolved_index_digest" == "$expected_index_digest" ]]

  singularity build --sandbox --fix-perms "$sandbox" \
    "docker://lmsysorg/sglang-rocm@$expected_index_digest"
  mksquashfs "$sandbox" "$partial" \
    -noappend -comp lzo -b 131072 -noD -all-root
  mv "$partial" "$image"

  image_sha256="$(sha256sum "$image" | awk '{print $1}')"
  {
    printf 'source_ref=docker.io/lmsysorg/sglang-rocm:%s\n' "$tag"
    printf 'source_index_digest=%s\n' "$expected_index_digest"
    printf 'sglang_commit=%s\n' cdbfe90b4a6c728e03e6520862d792501b3a97bb
    printf 'aiter_commit=%s\n' c16d44b93a528b2a4bfd6d8d3409116d465872a9
    printf 'conversion=singularity-4.0.0 sandbox --fix-perms, then mksquashfs -noappend -comp lzo -b 131072 -noD -all-root\n'
    printf 'sandbox=%s\n' "$sandbox"
    printf 'sqsh_sha256=%s\n' "$image_sha256"
    printf 'completed_at=%s\n' "$(date --iso-8601=seconds)"
  } >"$provenance"
  verify_image
}

printf 'started_at=%s\nnode=%s\n' "$(date --iso-8601=seconds)" "$(hostname)"
download_model &
model_pid=$!
build_image &
image_pid=$!

model_rc=0
image_rc=0
wait "$model_pid" || model_rc=$?
wait "$image_pid" || image_rc=$?
printf 'bootstrap_return_codes model=%s image=%s\n' "$model_rc" "$image_rc"
(( model_rc == 0 && image_rc == 0 )) || exit 1

verify_model
verify_image
du -sh "$model_snapshot" "$image" "$root/cache/aiperf-mmap"
printf 'completed_at=%s\n' "$(date --iso-8601=seconds)"
