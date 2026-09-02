# Frontier objective completed

## Status

The 12-anchor aggregate objective was achieved on 2026-09-02 with accepted
sustained evidence.

| Quantity | Value |
|---|---:|
| Frozen mean P90 interactivity | 119.92649667 tok/s/user |
| Required relative improvement | 20% |
| Required mean P90 interactivity | 143.91179600 tok/s/user |
| Accepted mean P90 interactivity | 144.16638167 tok/s/user |
| Accepted relative improvement | **20.21228475%** |
| Margin above target | 0.25458567 tok/s/user |
| Provisional evidence used | no |
| Throughput-floor regressions | none |

The authoritative inputs and output are:

- `data/frozen_frontier_objective_20260901.json`
- `data/qwen35_frontier_accepted_portfolio_20260902.json`
- `data/qwen35_frontier_accepted_evaluation_20260902.json`

Verify the result with:

```bash
python3 scripts/evaluate_frontier_objective.py \
  --candidates data/qwen35_frontier_accepted_portfolio_20260902.json \
  --require-target
```

## Acceptance rule

The objective froze 12 best-known MI355X Pareto anchors published on
2026-09-01. Each anchor defines a throughput floor. At each floor, the score is
the highest P90 full-response interactivity from the frozen point or a valid
accepted candidate whose throughput per GPU is at least that floor.

Individual anchors did not each need to improve by 20%. Some could move more,
some less, and some remain unchanged. The objective passes when the arithmetic
mean of all 12 selected P90 values is at least 20% above the frozen mean.

ITL is excluded. A result below an anchor's throughput floor cannot advance that
anchor. Existing accepted points remain available, so no anchor can regress.
Screens and incomplete confirmations are provisional and cannot prove
completion.

## Accepted portfolio

| Accepted point | Throughput/GPU | P90 interactivity | Contribution to final selection |
|---|---:|---:|---|
| C4/maxrun-1 | 9,713.45409 | 285.02586 | accepted evidence; later dominated by C8 |
| C8/maxrun-1 | 14,542.23218 | 289.66929 | advances a01-a03 |
| C12/maxrun-1 | 14,318.01948 | 283.26609 | accepted evidence; later dominated by C8 |
| C12/maxrun-2 | 21,921.58888 | 212.24655 | advances a04 |
| C12/maxrun-6 | 30,453.91358 | 126.37218 | advances a06; crosses aggregate target |

The frozen C12/maxrun-4 result remains selected at a05. Frozen high-throughput
results remain selected at a07-a12. In total, six anchors improved and six were
unchanged.

Every new portfolio entry completed:

1. a bounded 900-second-class qualification with stable endpoint controls or an
   explicit cross-throughput-floor promotion;
2. a separate 3,600-second-class confirmation;
3. request accounting, zero-error, power, checksum, route, and fault gates; and
4. an independently allocated clean eight-GPU postflight.

## Optimization path

The search stayed on points capable of advancing a frozen throughput floor.

- Admission-cap screening established useful C12 operating points at maxrun 1,
  2, 4, and 6.
- Client-concurrency testing showed that C8/maxrun-1 dominates the accepted C4
  and C12 maxrun-1 points at the low-throughput end.
- The combined SGLang #35872 + #37465 and AITER #5190 overlay improved the
  low-concurrency path through split top-k-1 draft selection and gfx950 assembly
  MTP verify attention.
- Page size 64 at C4 was valid but dominated:
  7,852.73234 tok/s/GPU at P90 274.66539.
- SGLang #37113 was retired for this workload because its patched serving arm
  emitted no fused-decode route marker on the target-verification path.
- The earlier BF16 GEMM candidate was retired because the intended tuned route
  engaged zero times and serving throughput did not improve.
- Conditional maxrun-4 follow-up work was skipped after the accepted maxrun-6
  postflight proved the aggregate target.

## Completion boundary

This document records the completed objective; it does not silently define a
new one. Any further optimization should start from the 2026-09-02 accepted
frontier and state a new metric, target, and evidence gate before launching
additional MI355X runs.
