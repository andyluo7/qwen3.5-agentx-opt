# Validated results

## Aggregate frontier objective: achieved

The accepted portfolio improves the arithmetic mean of P90 full-response
interactivity across the 12 frozen MI355X throughput floors by **20.212285%**.
ITL is excluded, every selected result satisfies its anchor's throughput floor,
and no provisional result is used.

| Quantity | Value |
|---|---:|
| Frozen mean P90 interactivity | 119.92649667 tok/s/user |
| Required mean at +20% | 143.91179600 tok/s/user |
| Accepted mean P90 interactivity | 144.16638167 tok/s/user |
| Absolute mean gain | 24.23988500 tok/s/user |
| Relative mean gain | **20.21228475%** |
| Margin above target | 0.25458567 tok/s/user |
| Improved / unchanged anchors | 6 / 6 |
| Throughput-floor regressions | 0 |
| Provisional points selected | 0 |

The machine-readable definition is
`data/frozen_frontier_objective_20260901.json`. The accepted input and its
frozen evaluation are
`data/qwen35_frontier_accepted_portfolio_20260902.json` and
`data/qwen35_frontier_accepted_evaluation_20260902.json`.

## Selected 12-anchor portfolio

At each row, the evaluator chooses the highest accepted P90 interactivity whose
throughput per GPU is at least the frozen floor. One accepted point may advance
multiple anchors.

| Anchor | Throughput floor | Frozen P90 | Selected P90 | Gain | Selected result |
|---|---:|---:|---:|---:|---|
| a01 TP4/EP1 C1 | 3,642.93817 | 244.43371 | 289.66929 | +18.5063% | C8/maxrun-1 |
| a02 TP2/EP1 C1 | 7,154.29007 | 236.14097 | 289.66929 | +22.6680% | C8/maxrun-1 |
| a03 TP2/EP1 C4 | 11,268.78138 | 181.62544 | 289.66929 | +59.4872% | C8/maxrun-1 |
| a04 TP2/EP1 C8 | 19,504.46869 | 153.78368 | 212.24655 | +38.0163% | C12/maxrun-2 |
| a05 TP2/EP1 C12 maxrun-4 | 26,579.15484 | 147.60291 | 147.60291 | 0% | frozen accepted point |
| a06 TP2/EP1 C12 runner | 29,878.60324 | 100.76418 | 126.37218 | +25.4138% | C12/maxrun-6 |
| a07 TP2/EP2 C20 | 43,292.13539 | 86.64070 | 86.64070 | 0% | frozen accepted point |
| a08 TP2/EP2 C22 | 43,632.97300 | 81.13203 | 81.13203 | 0% | frozen accepted point |
| a09 TP2/EP2 C32 | 46,811.57575 | 78.78076 | 78.78076 | 0% | frozen accepted point |
| a10 TP2/EP1 C24 | 53,830.02915 | 51.54155 | 51.54155 | 0% | frozen runner point |
| a11 TP2/EP1 C28 | 56,457.73823 | 41.66606 | 41.66606 | 0% | frozen runner point |
| a12 TP2/EP1 C32 | 59,050.50029 | 35.00597 | 35.00597 | 0% | frozen runner point |

This is the agreed aggregate rule: the individual anchors do not each need a
20% move. The arithmetic mean across all 12 anchors must move at least 20%.

## Accepted sustained low-concurrency results

All five new portfolio entries completed a 3,600-second-class confirmation and
an independent clean eight-GPU postflight.

| Point | Throughput/GPU | P90 interactivity | Measured duration | Profiled requests | Avg. power | Final role |
|---|---:|---:|---:|---:|---:|---|
| C4/maxrun-1 | 9,713.45409 | 285.02586 | 3,609.00553 s | 755 | 543.631 W/GPU | accepted, later dominated by C8 |
| C8/maxrun-1 | 14,542.23218 | 289.66929 | 3,619.63816 s | 1,127 | 621.192 W/GPU | advances a01-a03 |
| C12/maxrun-1 | 14,318.01948 | 283.26609 | 3,629.47229 s | 1,053 | 626.851 W/GPU | accepted, later dominated by C8 |
| C12/maxrun-2 | 21,921.58888 | 212.24655 | 3,626.76033 s | 1,552 | 667.900 W/GPU | advances a04 |
| C12/maxrun-6 | 30,453.91358 | 126.37218 | 3,622.06436 s | 2,206 | 697.084 W/GPU | advances a06 and completes target |

The accepted C12/maxrun-4 point remains the selected result at a05:
26,579.15484 tok/s/GPU and P90 147.60291 tok/s/user. It is a runtime scheduling
optimization on the merged baseline and requires no additional source patch.

## Final C12/maxrun-6 confirmation

The completing point uses:

| Field | Value |
|---|---|
| Hardware / node | AMD Instinct MI355X / `vultr-mi355x-5` |
| Topology | TP2/EP1 |
| AgentX concurrency | 12 |
| Max running requests | 6 |
| Decode graph max batch | 24 |
| KV cache | Resident FP8, page size 16 |
| Prefill/chunk limit | 16,384 tokens |
| Scheduler receive interval | 30 |
| Speculative decoding | EAGLE MTP |
| Total throughput/GPU | 30,453.91358 tok/s |
| P90 full-response interactivity | 126.37218 tok/s/user |
| Measured duration | 3,622.06436 s |
| Profiled / warmup / error records | 2,206 / 131 / 0 |
| Input/output tokens | 219,044,844 / 2,040,948 |
| Average power | 697.084 W/GPU |

The 900-second qualification was a maxrun-5 → maxrun-6 → maxrun-5 bracket.
Its two controls measured 32,145.10988 / 131.59335 and
32,012.68219 / 129.77722 (throughput/GPU / P90 interactivity). The maxrun-6
candidate measured 33,697.31802 / 112.01359. It advanced the next throughput
floor in the portfolio and was therefore eligible for sustained confirmation;
it was not promoted as a same-floor P90 win over maxrun-5.

### Validation gates

- The raw audit found 2,206 profiling records and recomputed P90 interactivity
  as 126.37217947327983 tok/s/user. Its absolute delta from the aggregate was
  5.2672e-7, below the 1e-4 tolerance.
- Profiling completed 2,206 successful requests after 131 excluded warmups,
  with zero request errors and no cancelled profiling record.
- Both GPUs had valid telemetry. Average power was 697.084 W/GPU and the
  two-GPU energy-accumulator discrepancy was 0.247326%, below the 5% gate.
- Route evidence observed two draft-decode top-k-1 markers, two draft-extend
  top-k-1 markers, and three AITER MTP verify-ASM markers.
- The SGLang and AITER overlays matched SHA256
  `d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3`
  and
  `10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09`.
- No HIP/GPU fault signature was present, archive checksums passed, and the
  independent postflight found all eight cards idle with no listeners,
  workload processes, KFD users, elevated VRAM, or recent GPU fault.
- Slurm jobs 2676 (confirmation) and 2679 (postflight) completed successfully.
  The conditional maxrun-4 fallback, job 2678, skipped benchmarking because the
  accepted target had already been met.

## B200 and current-MI355X context

At the matching C12 runner point, InferenceX B200 run 30758866378 attempt 1
reported 29,755.23348 tok/s/GPU and P90 145.60570 tok/s/user. The two accepted
C12 tradeoff points give different operating choices:

| MI355X point | Throughput vs B200 | P90 interactivity vs B200 |
|---|---:|---:|
| maxrun-4 | 89.325983% | 101.371656% |
| maxrun-6 | 102.348091% | 86.790682% |

Both clear the campaign's 70%-of-B200 threshold on both metrics. The aggregate
20% objective is separate: it is measured against the frozen MI355X frontier,
not against a single B200 point.

## Pareto artifact

The dated chart compares:

- current MI355X aggregates from InferenceX run 33298482346 attempt 1;
- B200 aggregates from InferenceX run 30758866378 attempt 1; and
- the best-known MI355X set formed from the current runner and accepted
  sustained campaign results.

The plotting code computes nondominated points in P90 interactivity versus
total throughput per GPU. The complete point table is
`artifacts/Qwen3.5_AgentX_Pareto_MI355X_Optimized_vs_Current_vs_B200_2026-09-02.csv`;
the matching PNG is in the same directory. The 2026-09-01 files are retained as
the pre-objective historical snapshot.
