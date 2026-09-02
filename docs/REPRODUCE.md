# Reproduction guide

## Scope

This repository supports three independent levels of reproduction:

1. recompute the completed 12-anchor objective from checked-in accepted data;
2. regenerate the dated MI355X/B200 Pareto chart and CSV; and
3. repeat the maxrun-6 qualification, sustained confirmation, raw audit, and
   full-node postflight on the AAC17 MI355X environment.

ITL is excluded. The acceptance metrics are total throughput per GPU and P90
full-response interactivity.

## Verify the checked-in objective

From the repository root:

```bash
python3 scripts/evaluate_frontier_objective.py \
  --candidates data/qwen35_frontier_accepted_portfolio_20260902.json \
  --require-target
```

Expected summary:

```text
baseline_mean=119.92649667
new_mean=144.16638167
relative_mean_gain_pct=20.212285
target_mean=143.91179600
remaining_mean_gain=0.00000000
uses_provisional=0
objective_achieved=1
```

The frozen JSON form of the same result is
`data/qwen35_frontier_accepted_evaluation_20260902.json`. A provisional screen
may be ranked with `--include-provisional`, but it can never prove completion.

## Regenerate the accepted Pareto artifacts

With Python 3 and Matplotlib installed:

```bash
MPLCONFIGDIR=/tmp/qwen35-mpl \
python3 scripts/build_qwen35_agentx_pareto_20260901.py \
  --output-stem \
  artifacts/Qwen3.5_AgentX_Pareto_MI355X_Optimized_vs_Current_vs_B200_2026-09-02
```

Expected inventory:

```text
B200: 33 points, 13 frontier
Current MI355X: 24 points, 11 frontier
Best-known MI355X: 37 points, 10 frontier
```

The best-known CSV frontier must contain the accepted C8/maxrun-1,
C12/maxrun-2, C12/maxrun-4, and C12/maxrun-6 points. The older 2026-09-01
artifacts are intentionally retained as the pre-objective snapshot.

## AAC17 prerequisites

The runtime workflow assumes:

- account `r7n`, partition `256C8G1H_MI355X_Ubuntu24`, and the recorded
  six-node AAC17 reservation;
- one genuinely idle eight-GPU MI355X node; the completing run used
  `vultr-mi355x-5`;
- Enroot/Pyxis and the pinned SGLang ROCm image already staged;
- the exact InferenceX, AIPerf, SGLang, AITER, model, and image pins listed in
  `SOURCE_PROVENANCE.md`;
- AIPerf and Hugging Face caches under the benchmark root; and
- `srun`, `squeue`, `ss`, `fuser`, `journalctl`, `jq`, and
  `sha256sum`.

Before submitting, verify Slurm ownership and actual GPU state: no competing
allocation, `/dev/kfd` user, active GPU process, elevated VRAM, port 8888
listener, or recent GPU fault. Scheduler-idle state alone is insufficient.

## Stage the reviewed launchers

The historical remote deployment used a versioned filename for the generic
confirmation launcher. The following staging keeps the checked-in scripts
unchanged while recreating that layout:

```bash
export SHARED_ROOT=/shared/amdgpu/home/andy_luo_3v7

install -m 0755 scripts/run_and_archive_node2.sh \
  "$SHARED_ROOT/run_and_archive_node2.sh"
install -m 0755 scripts/run_qwen35_pr2737_c12_exact_point_node2.sh \
  "$SHARED_ROOT/run_qwen35_pr2737_c12_exact_point_node2.sh"
install -m 0755 scripts/evaluate_frontier_objective.py \
  "$SHARED_ROOT/evaluate_frontier_objective.py"
install -m 0644 data/frozen_frontier_objective_20260901.json \
  "$SHARED_ROOT/frozen_frontier_objective_20260901.json"

install -m 0755 scripts/run_qwen35_pr2737_c12_maxrun_ladder_node2.sh \
  "$SHARED_ROOT/run_qwen35_pr2737_c12_maxrun_ladder_node2.sh"
install -m 0755 scripts/run_qwen35_frontier_confirm_node2.sh \
  "$SHARED_ROOT/run_qwen35_frontier_confirm_v4.sh"
install -m 0755 scripts/run_qwen35_frontier_postflight_node2.sh \
  "$SHARED_ROOT/run_qwen35_frontier_postflight_node2.sh"
install -m 0755 scripts/run_qwen35_frontier_postflight_after_confirmation.sh \
  "$SHARED_ROOT/run_qwen35_frontier_postflight_after_confirmation.sh"
install -m 0755 scripts/run_qwen35_confirm_combined_candidate_after_screen.sh \
  "$SHARED_ROOT/run_qwen35_confirm_combined_candidate_after_screen.sh"
install -m 0755 scripts/run_qwen35_maxrun6_if_target_missing_node5.sh \
  "$SHARED_ROOT/run_qwen35_maxrun6_if_target_missing_node5.sh"

install -m 0644 patches/sglang_pr35872_pr37465_combined_instrumented.patch \
  "$SHARED_ROOT/sglang_pr35872_pr37465_combined_instrumented.patch"
install -m 0644 patches/aiter_pr5190_mtp_verify_attn_asm.patch \
  "$SHARED_ROOT/aiter_pr5190_mtp_verify_attn_asm.patch"
```

The exact-point launcher checksum must be
`cb6f1e1526c46176d0326e2a9f05ecfae73a40cf4209f6bbad890eb3a9561bb8`.
The combined SGLang and AITER overlay checksums must be
`d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3`
and
`10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09`.

## Repeat the completing maxrun-6 chain

The target-gated wrapper evaluates the four earlier accepted points first. If
that portfolio still misses 20%, it runs a maxrun-5 → maxrun-6 → maxrun-5
screen with the qualified overlays, submits a 3,600-second confirmation for the
selected maxrun-6 result, and then submits an independent eight-GPU postflight.

The four base postflight stdout files from the accepted campaign were:

```bash
export SHARED_ROOT=/shared/amdgpu/home/andy_luo_3v7
export POSTFLIGHT_STDOUTS="\
$SHARED_ROOT/qwen35-frontier-postflight-after-confirm-2573.out \
$SHARED_ROOT/qwen35-frontier-postflight-after-confirm-2579.out \
$SHARED_ROOT/qwen35-frontier-postflight-after-confirm-2620.out \
$SHARED_ROOT/qwen35-frontier-postflight-after-confirm-2625.out"

sbatch --export=ALL,TARGET_NODE=vultr-mi355x-5 \
  scripts/run_qwen35_maxrun6_if_target_missing_node5.sh
```

Each referenced stdout must resolve exactly one accepted manifest. Supplying the
already accepted maxrun-6 postflight as a base input intentionally causes the
wrapper to skip, because the objective is already complete.

The qualification requires:

- at least 900 seconds per arm;
- stable endpoint controls;
- exact source, launcher, patch, and command pins;
- expected draft-decode, draft-extend, and MTP verify-ASM route markers;
- complete request and warmup accounting with zero errors;
- valid power and archive checksums;
- no HIP/GPU fault signature; and
- clean per-arm teardown.

The confirmation remains provisional until the separate eight-GPU postflight
promotes its one-point manifest to `accepted`.

## Audit the canonical maxrun-6 result

The canonical archive is:

```text
/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results/qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6_maxrun6_graph24_page16_3600s_confirm_20260902T172507-0500
```

Recompute P90 full-response interactivity directly from the raw profiling
records:

```bash
python3 scripts/audit_raw_interactivity.py \
  /shared/data/R7N/andy_luo_3v7/qwen35-agentx-results/qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6_maxrun6_graph24_page16_3600s_confirm_20260902T172507-0500
```

Expected values are 2,206 profiling records, raw P90
126.37217947327983 tok/s/user, reported P90 126.37218, and an absolute delta
below 1e-4.

## Reproduce the original patch-free C12 point

The frozen a05 point is independent of the later overlays. It uses
`max-running-requests=4`, graph capacity 24, and the merged source baseline.

Qualification:

```bash
sbatch --export=ALL,DURATION=900,CONTROL_MAXRUN=24,CANDIDATE_MAXRUN=4,CUDA_GRAPH_MAX_BS_OVERRIDE=24 \
  scripts/run_qwen35_pr2737_c12_maxrun12_bracket_node2.sh
```

Sustained confirmation:

```bash
sbatch --export=ALL,MAX_RUNNING_REQUESTS_OVERRIDE=4,CUDA_GRAPH_MAX_BS_OVERRIDE=24,DURATION=3600,QUALIFICATION_SUMMARY=/path/to/bracket.tsv,QUALIFICATION_DECISION=/path/to/bracket.decision.txt \
  scripts/run_qwen35_pr2737_c12_confirm_node2.sh
```

Then run `scripts/run_qwen35_pr2737_c12_postflight_node2.sh` only after the
two-GPU allocation has fully released. Promotion requires the full-node output
to print `CLEAN`.

## Repository validation

Before publishing a regenerated handoff:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
python3 -m py_compile scripts/*.py
python3 -m unittest discover -s tests -v
python3 scripts/evaluate_frontier_objective.py \
  --candidates data/qwen35_frontier_accepted_portfolio_20260902.json \
  --require-target
sha256sum -c SHA256SUMS
git diff --check
```
