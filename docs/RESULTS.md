# Validated results

## Accepted C12 Pareto point

The accepted result is a 3,600-second confirmation of the candidate first
qualified by a 900-second control/candidate/control bracket.

| Field | Value |
|---|---|
| Hardware | AMD Instinct MI355X |
| Topology | TP2/EP1 |
| AgentX concurrency | 12 |
| Max running requests | 4 |
| Decode graph max batch | 24 |
| KV cache | Resident FP8, page size 16 |
| Prefill/chunk limit | 16,384 tokens |
| Scheduler receive interval | 30 |
| Speculative decoding | EAGLE MTP |
| Total throughput/GPU | 26,579.15484 tok/s |
| P90 full-response interactivity | 147.60291 tok/s/user |
| Measured duration | 3,623.63864 s |
| Profiled requests | 1,927 successful |
| Excluded warmups | 131 |
| Request errors | 0 |
| Input/output tokens | 190,789,764 / 1,836,741 |
| Average power | 695.536558 W/GPU |

Raw-record reanalysis found 1,927 unique profiling records and 131 warmup
records, with no cancellation or context-overflow skip. Of the profiling
records, 1,925 had a defined full-response per-user throughput; their raw P10
was 147.60292155147945 tok/s/user, reproducing the reported P90 interactivity
convention.

## Comparison

| Comparator | Throughput/GPU | P90 interactivity | Accepted MI355X throughput ratio | Accepted MI355X interactivity ratio |
|---|---:|---:|---:|---:|
| InferenceX MI355X run 33298482346, attempt 1 | 29,878.60324 | 100.76418 | 88.957153% | 146.483512% |
| InferenceX B200 run 30758866378, attempt 1 | 29,755.23348 | 145.60570 | 89.325983% | 101.371656% |

The campaign target was 70% of B200, not 170%. Only throughput and P90
full-response interactivity are acceptance metrics. The accepted C12 point
clears both B200-relative thresholds and improves the current MI355X runner's
P90 interactivity by 46.483512%.

## Qualification bracket

The 900-second A/B/A bracket held graph capacity at 24 and changed only
`max-running-requests` from the control value 24 to candidate value 4.

| Arm | Throughput/GPU | P90 interactivity | Duration | Profiled/warmup/errors |
|---|---:|---:|---:|---:|
| maxrun-24 control 1 | 33,654.96766 | 87.40705 | 916.90962 s | 646/131/0 |
| maxrun-4 candidate | 28,646.51291 | 140.06170 | 912.30244 s | 574/131/0 |
| maxrun-24 control 2 | 33,238.57386 | 82.74441 | 923.82282 s | 644/131/0 |

Against the control mean, the candidate traded 14.351932% throughput for
64.631793% higher P90 interactivity. The independent 3,600-second confirmation
then preserved the Pareto move.

## Evidence gates

- All 34 archive-manifest entries passed checksum verification.
- Both allocated GPUs produced 3,612 power samples each with a maximum 2.0 s
  sample gap.
- Energy accumulator comparison had 0.162948% relative error.
- The server log contained exactly one server-process startup and one Uvicorn
  startup.
- Profiling completed 1,927/1,927 requests with zero request errors.
- The confirmation, conditional fallback, and full-node postflight Slurm jobs
  all exited `0:0`.
- The postflight acquired all eight GPUs and found no listener, workload
  process, `/dev/kfd` user, elevated VRAM, GPU activity, or recent fault
  signature.

AIPerf emitted counter-reset warnings while exporting server metrics. There
was no server restart; the terminal `SystemExit: 0` and `asyncio.CancelledError`
followed deliberate teardown. Request-derived throughput and interactivity are
unaffected.

## Pareto artifact

The chart compares:

- current MI355X aggregates from InferenceX run 33298482346 attempt 1;
- B200 aggregates from InferenceX run 30758866378 attempt 1; and
- the best-known MI355X set formed from the current runner plus accepted
  sustained tuning results.

The plotting code computes nondominated points in P90 interactivity versus
total throughput per GPU. The complete point table, including whether each row
is on its series frontier, is in
`artifacts/Qwen3.5_AgentX_Pareto_MI355X_Optimized_vs_Current_vs_B200_2026-09-01.csv`.

The higher-concurrency accepted MI355X points included in the plot are TP2/EP2
C16, C18, C20, C22, C24, C28, and C32. They are retained as measured campaign
results, but only nondominated points are drawn as frontier segments.
