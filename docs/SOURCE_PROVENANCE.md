# Source and artifact provenance

## Frozen source and model pins

| Component | Revision |
|---|---|
| InferenceX | [`875cd72b3c1b67a4d7fde75cf5ae1e028dd95fb7`](https://github.com/SemiAnalysisAI/InferenceX/commit/875cd72b3c1b67a4d7fde75cf5ae1e028dd95fb7) |
| AIPerf | `754356e9a39acc6cc6afb242d123bb57c3fb6f75` |
| SGLang | [`cdbfe90b4a6c728e03e6520862d792501b3a97bb`](https://github.com/sgl-project/sglang/commit/cdbfe90b4a6c728e03e6520862d792501b3a97bb) |
| AITER | [`c16d44b93a528b2a4bfd6d8d3409116d465872a9`](https://github.com/ROCm/aiter/commit/c16d44b93a528b2a4bfd6d8d3409116d465872a9) |
| Model | `amd/Qwen3.5-397B-A17B-MXFP4` at `edf0958bc3734dda98a9d191cc7a0a83c4f42821` |

The launch script also records recipe fingerprint `ecf94fe385859291` and uses
the staged image
`lmsysorg_sglang-rocm_v0.5.18-rocm720-mi35x-20260829.sqsh`. The benchmark
archive contains the image provenance record, image checksum, copied effective
recipe, source-file checksums, exact SGLang command, logs, aggregate, raw
records, telemetry, teardown snapshot, and checksum manifest.

## Comparator runners

- Current MI355X: [InferenceX Actions run 33298482346, attempt 1](https://github.com/SemiAnalysisAI/InferenceX/actions/runs/33298482346/attempts/1)
- Matching B200: [InferenceX Actions run 30758866378, attempt 1](https://github.com/SemiAnalysisAI/InferenceX/actions/runs/30758866378/attempts/1)

The repository's `data/current_mi355x_33298482346_attempt1/` and
`data/b200_30758866378_attempt1/` directories contain the aggregate JSON files
extracted from those runner artifacts. The original zip payloads are omitted
because the extracted aggregates are sufficient for the checked-in chart.

## Accepted MI355X evidence

Canonical confirmation archive:

```text
/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results/qwen35_pr2737_tp2ep1_c12_exact_maxrun4_graph24_3600s_confirm_20260901T001648-0500
```

Associated AAC17 evidence:

```text
/shared/amdgpu/home/andy_luo_3v7/qwen35_pr2737_tp2ep1_c12_exact_maxrun4_graph24_3600s_confirm_20260901T001648-0500.decision.txt
/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-maxrun24-vs4-900s-aba-20260831T231004-0500.tsv
/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-maxrun24-vs4-900s-aba-20260831T231004-0500.decision.txt
/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-confirm-postflight-2463.txt
```

The large raw confirmation archive remains on shared storage and is not copied
into Git. The reported result should not be treated as reproduced elsewhere
without the same manifest, request accounting, telemetry, teardown, and
postflight gates.
