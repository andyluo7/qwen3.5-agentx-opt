# Candidate and accepted source overlays

These files preserve the exact source overlays tested against frozen SGLang
`cdbfe90b4a6c728e03e6520862d792501b3a97bb` and AITER
`c16d44b93a528b2a4bfd6d8d3409116d465872a9`. Some are historical candidates;
the combined SGLang #35872 + #37465 overlay and AITER #5190 overlay are inputs to
the accepted low-concurrency portfolio.

| File | Upstream source | Benchmarked head | Campaign outcome |
|---|---|---|---|
| `sglang_pr37113_rocm_gdn_decode.patch` | SGLang #37113 | `d6858193842ab56c3d9d41cbb966d85d2397aaa9` | Retired: the AgentX MTP serving arm emitted no fused-decode route marker |
| `sglang_pr35872_rocm_topk1.patch` | SGLang #35872 | `6ac718f05f067214368460ce93d9b19f5c889f5b` | Functional split-argmax change used by the accepted combined overlay |
| `sglang_pr35872_rocm_topk1_instrumented.patch` | SGLang #35872 plus benchmark-only logging | `6ac718f05f067214368460ce93d9b19f5c889f5b` | Adds one-time draft-decode and draft-extend route markers |
| `sglang_pr34005_draft_extend_lm_head_prune.patch` | SGLang #34005 | `f8cab1abe5bce5f5354c545938c67fa5d896e961` | Historical candidate; not required by the accepted portfolio |
| `sglang_pr34005_draft_extend_lm_head_prune_instrumented.patch` | SGLang #34005 plus benchmark-only logging | `f8cab1abe5bce5f5354c545938c67fa5d896e961` | Historical route-instrumented candidate |
| `sglang_pr33778_strided_target_verify_qkv.patch` | SGLang #33778 | `f0b834be9b89f316f2daed9dc6f78e06df300e4b` | Historical candidate; not required by the accepted portfolio |
| `sglang_pr33778_strided_target_verify_qkv_instrumented.patch` | SGLang #33778 plus benchmark-only logging | `f0b834be9b89f316f2daed9dc6f78e06df300e4b` | Historical route-instrumented candidate |
| `sglang_pr37465_aiter_mtp_verify_attn.patch` | SGLang #37465 | `766c02152d5a041d5b4e1a61fdd8691e1bd7515f` | Accepted integration for the gfx950 MTP verify-attention path |
| `aiter_pr5190_mtp_verify_attn_asm.patch` | AITER #5190 | `8fb158c83a53e14c49e825423211620466eb103a` | Accepted gfx950 `mtp_verify_attn_fwd_asm` implementation |
| `sglang_pr35872_pr37465_combined_instrumented.patch` | SGLang #35872 + #37465 plus benchmark-only logging | #35872 `6ac718f05f067214368460ce93d9b19f5c889f5b`; #37465 `766c02152d5a041d5b4e1a61fdd8691e1bd7515f` | Accepted combined qualification and confirmation input |

The non-instrumented files contain only runtime source changes. The
instrumented variants add one-time route logging after the functional branch is
selected. Warmup exercises the markers before profiling, allowing the archived
server log to prove which implementation ran.

SGLang #33068 is excluded because it does not apply cleanly to the frozen pin
and primarily targets the AttnFP8-V2 checkpoint's uniform input-projection
quantization.

## Accepted combined overlay

The accepted input checksums are:

```text
d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3  sglang_pr35872_pr37465_combined_instrumented.patch
10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09  aiter_pr5190_mtp_verify_attn_asm.patch
```

An exact-pin smoke exercised five correctness shapes and observed the
production-shape assembly route. The 900-second maxrun-1, maxrun-2, maxrun-5,
and maxrun-6 AgentX brackets observed both #35872 route markers and the AITER
assembly-module marker.

The selected C4/maxrun-1, C8/maxrun-1, C12/maxrun-1, C12/maxrun-2, and
C12/maxrun-6 points then completed 3,600-second confirmations and independent
full-node postflights. Their accepted portfolio is
`data/qwen35_frontier_accepted_portfolio_20260902.json`.

Upstream PR heads can move after benchmarking. The accepted claims remain bound
to these patch bytes and checksums; see `docs/UPSTREAM_STATUS.md` for live
status.
