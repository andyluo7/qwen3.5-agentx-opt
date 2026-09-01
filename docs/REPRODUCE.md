# Reproduction guide

## Scope and prerequisites

The benchmark scripts reproduce the accepted C12 result on the AAC17 Slurm
environment used by the campaign. They assume:

- an MI355X node with the `r7n` account and the recorded AAC17 reservation;
- Enroot/Pyxis support and the pinned SGLang ROCm image already staged;
- the exact InferenceX checkout and model snapshot listed in
  `SOURCE_PROVENANCE.md`;
- AIPerf and Hugging Face caches under the benchmark root; and
- GNU/Linux utilities used by the evidence gates (`srun`, `squeue`, `ss`,
  `fuser`, `journalctl`, and `sha256sum`).

The checked-in scripts preserve the original cluster paths. Override
`SHARED_ROOT`, `ARCHIVE_ROOT`, `BENCH_ROOT`, `INFERENCEX_REPO`, and
`TARGET_NODE` when using a different layout.

## Stage the launchers

The wrappers expect the archival helper and exact-point launcher directly in
`SHARED_ROOT`:

```bash
install -m 0755 scripts/run_and_archive_node2.sh "$SHARED_ROOT/"
install -m 0755 scripts/run_qwen35_pr2737_c12_exact_point_node2.sh "$SHARED_ROOT/"
```

Before submitting a benchmark, verify that the selected node is genuinely
clean: no competing Slurm allocation, `/dev/kfd` user, active GPU workload,
elevated VRAM, listener on the benchmark port, or recent GPU fault.

## Run the exact baseline

```bash
sbatch --export=ALL,DURATION=120 \
  scripts/run_qwen35_pr2737_c12_exact_baseline_node2.sh
```

The exact-environment maxrun-24 baseline recorded during the campaign was
33,272.71224 tok/s/GPU and 91.12869 tok/s/user.

## Qualify maxrun 4

The bracket script retains its historical filename and defaults to candidate
12. Set `CANDIDATE_MAXRUN=4` explicitly to reproduce the accepted candidate:

```bash
sbatch --export=ALL,DURATION=900,CONTROL_MAXRUN=24,CANDIDATE_MAXRUN=4,CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  scripts/run_qwen35_pr2737_c12_maxrun12_bracket_node2.sh
```

Do not advance unless the generated decision file contains
`advance_to_3600s=1`, every arm completed all expected warmups with zero
request errors, and the node/evidence checks passed.

## Run the sustained confirmation

Pass the bracket outputs back into the confirmation wrapper:

```bash
sbatch --export=ALL,MAX_RUNNING_REQUESTS_OVERRIDE=4,CUDA_GRAPH_MAX_BS_OVERRIDE=24,DURATION=3600,QUALIFICATION_SUMMARY=/path/to/bracket.tsv,QUALIFICATION_DECISION=/path/to/bracket.decision.txt \
  scripts/run_qwen35_pr2737_c12_confirm_node2.sh
```

The wrapper independently enforces duration, topology, source pins, command
shape, checksums, request accounting, throughput/interactivity gates, power
coverage, startup count, and fault scans.

## Run the full-node postflight

After the two-GPU confirmation allocation has fully released, acquire all eight
GPUs and run:

```bash
sbatch scripts/run_qwen35_pr2737_c12_postflight_node2.sh
```

Promotion requires the postflight to print `CLEAN`.

## Regenerate the Pareto chart

The repository includes the aggregate JSONs from both audited InferenceX
runners. With Python 3 and Matplotlib installed:

```bash
python3 scripts/build_qwen35_agentx_pareto_20260901.py
```

By default, regenerated files are written below `artifacts/reproduced/` so the
accepted snapshot is not overwritten. Use `--current-dir`, `--b200-dir`, or
`--output-stem` to supply alternative inputs or output paths.
