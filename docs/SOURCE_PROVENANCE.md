# Source and artifact provenance

## Frozen source, model, and image pins

| Component | Revision |
|---|---|
| InferenceX | [`875cd72b3c1b67a4d7fde75cf5ae1e028dd95fb7`](https://github.com/SemiAnalysisAI/InferenceX/commit/875cd72b3c1b67a4d7fde75cf5ae1e028dd95fb7) |
| AIPerf | `754356e9a39acc6cc6afb242d123bb57c3fb6f75` |
| SGLang base | [`cdbfe90b4a6c728e03e6520862d792501b3a97bb`](https://github.com/sgl-project/sglang/commit/cdbfe90b4a6c728e03e6520862d792501b3a97bb) |
| AITER base | [`c16d44b93a528b2a4bfd6d8d3409116d465872a9`](https://github.com/ROCm/aiter/commit/c16d44b93a528b2a4bfd6d8d3409116d465872a9) |
| Model | `amd/Qwen3.5-397B-A17B-MXFP4` at `edf0958bc3734dda98a9d191cc7a0a83c4f42821` |
| Recipe fingerprint | `ecf94fe385859291` |
| Image | `lmsysorg_sglang-rocm_v0.5.18-rocm720-mi35x-20260829.sqsh` |

The raw archives contain the image provenance record and checksum, copied
effective recipe, source-file checksums, exact SGLang command, server and client
logs, aggregate, raw request records, power telemetry, teardown snapshot, and
archive checksum manifest.

## Accepted overlay pins

The new low-concurrency results apply the following benchmark inputs to the
frozen bases:

| Input | Upstream basis | Benchmarked head | SHA256 |
|---|---|---|---|
| `patches/sglang_pr35872_pr37465_combined_instrumented.patch` | SGLang #35872 + #37465 plus one-time route logging | #35872 `6ac718f05f067214368460ce93d9b19f5c889f5b`; #37465 `766c02152d5a041d5b4e1a61fdd8691e1bd7515f` | `d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3` |
| `patches/aiter_pr5190_mtp_verify_attn_asm.patch` | AITER #5190 | `8fb158c83a53e14c49e825423211620466eb103a` | `10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09` |

The one-time instrumentation proves route engagement and does not alter the
functional kernel or scheduling behavior. Current upstream PR heads may have
moved after benchmarking; `UPSTREAM_STATUS.md` records both the benchmarked
and rechecked live heads.

## Comparator runners

- Current MI355X: [InferenceX Actions run 33298482346, attempt 1](https://github.com/SemiAnalysisAI/InferenceX/actions/runs/33298482346/attempts/1)
- Matching B200: [InferenceX Actions run 30758866378, attempt 1](https://github.com/SemiAnalysisAI/InferenceX/actions/runs/30758866378/attempts/1)

The repository's `data/current_mi355x_33298482346_attempt1/` and
`data/b200_30758866378_attempt1/` directories contain the aggregate JSON files
extracted from those runner artifacts. The original zip payloads are omitted;
the extracted aggregates are sufficient to regenerate the checked-in chart.

## Accepted low-concurrency archives

| Point | Canonical archive | Qualification | Independent postflight |
|---|---|---|---|
| C12/maxrun-1 | `qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm_maxrun1_graph24_page16_3600s_confirm_20260901T192658-0500` | `qwen35-pr2737-c12-pr35872-pr37465-aiter5190-mtpverifyasm-maxrun1-900s-aba-20260901T173211-0500` | job 2573 |
| C12/maxrun-2 | `qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm_maxrun2_graph24_page16_3600s_confirm_20260901T194843-0500` | `qwen35-pr2737-c12-pr35872-pr37465-aiter5190-mtpverifyasm-maxrun2-900s-aba-20260901T182013-0500` | job 2579 |
| C4/maxrun-1 | `qwen35_pr2737_tp2ep1_c4_pr35872-pr37465-aiter5190-mtpverifyasm-c4_maxrun1_graph24_page16_3600s_confirm_20260902T000958-0500` | `qwen35-pr2737-c4-pr35872-pr37465-aiter5190-mtpverifyasm-maxrun1-900s-aba-20260901T214540-0500` | job 2620 |
| C8/maxrun-1 | `qwen35_pr2737_tp2ep1_c8_pr35872-pr37465-aiter5190-mtpverifyasm-c8_maxrun1_graph24_page16_3600s_confirm_20260902T022509-0500` | `qwen35-pr2737-client-concurrency-maxrun1-900s-20260902T011836-0500` | job 2625 |
| C12/maxrun-6 | `qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6_maxrun6_graph24_page16_3600s_confirm_20260902T172507-0500` | `qwen35-pr2737-c12-maxrun-ladder-900s-20260902T161815-0500` | job 2679 |

Every archive name above is relative to:

```text
/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results/
```

The accepted portfolio preserves the exact absolute archive, qualification,
confirmation-decision, and postflight paths in
`data/qwen35_frontier_accepted_portfolio_20260902.json`.

## Completing maxrun-6 evidence

The completing run used Slurm job 2676 on `vultr-mi355x-5`. Its canonical
remote control-plane evidence is:

```text
/shared/amdgpu/home/andy_luo_3v7/qwen35-combined-confirm-after-screen-2676.out
/shared/amdgpu/home/andy_luo_3v7/qwen35-combined-qualification-2676-c12.candidates.json
/shared/amdgpu/home/andy_luo_3v7/qwen35-combined-qualification-2676-c12.decision.txt
/shared/amdgpu/home/andy_luo_3v7/qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6_maxrun6_graph24_page16_3600s_confirm_20260902T172507-0500.candidates.json
/shared/amdgpu/home/andy_luo_3v7/qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6_maxrun6_graph24_page16_3600s_confirm_20260902T172507-0500.evaluation.json
/shared/amdgpu/home/andy_luo_3v7/qwen35_pr2737_tp2ep1_c12_pr35872-pr37465-aiter5190-mtpverifyasm-maxrun6_maxrun6_graph24_page16_3600s_confirm_20260902T172507-0500.decision.txt
/shared/amdgpu/home/andy_luo_3v7/qwen35-frontier-postflight-after-confirm-2679.out
/shared/amdgpu/home/andy_luo_3v7/qwen35-frontier-postflight-2679.txt
```

Compact checked-in copies are:

- `data/qwen35_maxrun6_screen_20260902.tsv`
- `data/qwen35_maxrun6_screen_20260902.candidates.json`
- `data/qwen35_maxrun6_screen_20260902.decision.txt`
- `data/qwen35_maxrun6_aggregate_20260902.json`
- `data/qwen35_maxrun6_raw_audit_20260902.json`
- `data/qwen35_maxrun6_validation_20260902.txt`
- `data/qwen35_maxrun6_confirmation_20260902.decision.txt`
- `data/qwen35_maxrun6_postflight_20260902.txt`

The raw archive remains on shared storage because it is multi-gigabyte. The
checked-in compact evidence does not replace the raw request records, server
log, telemetry, or archive checksums when independently validating a new run.

## Original patch-free C12/maxrun-4 evidence

The frozen a05 result predates the combined overlays and requires no extra
SGLang or AITER source patch.

Canonical archive:

```text
/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results/qwen35_pr2737_tp2ep1_c12_exact_maxrun4_graph24_3600s_confirm_20260901T001648-0500
```

Associated control-plane evidence:

```text
/shared/amdgpu/home/andy_luo_3v7/qwen35_pr2737_tp2ep1_c12_exact_maxrun4_graph24_3600s_confirm_20260901T001648-0500.decision.txt
/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-maxrun24-vs4-900s-aba-20260831T231004-0500.tsv
/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-maxrun24-vs4-900s-aba-20260831T231004-0500.decision.txt
/shared/amdgpu/home/andy_luo_3v7/qwen35-pr2737-c12-confirm-postflight-2463.txt
```

No result should be treated as independently reproduced without matching source,
model, image, command, request accounting, raw P90 audit, telemetry, fault scan,
archive checksums, and clean postflight evidence.
