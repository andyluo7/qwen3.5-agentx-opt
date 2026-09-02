# Upstream status

Status was rechecked against GitHub on 2026-09-02.

## Merged work used by the campaign

| Project | PR | Merge commit | Role |
|---|---|---|---|
| SGLang | [#36330](https://github.com/sgl-project/sglang/pull/36330) | `c967cd19b56be8efed19e801357d437b5c1fe34c` | Qwen 3.5 MTP unified-attention optimization on gfx950 |
| SGLang | [#36758](https://github.com/sgl-project/sglang/pull/36758) | `acc918b3ece60af20321612b8ad204bdba8fcb80` | ASM FMHA chunked-prefill context attention |
| SGLang | [#36852](https://github.com/sgl-project/sglang/pull/36852) | `36afd70f9c064de4bbf552100b0dc91ee882c80d` | Token-level KV-index fix for AITER ASM context prefill |
| SGLang | [#36915](https://github.com/sgl-project/sglang/pull/36915) | `7f2ee22b70a755d82591d08388c7960f71d32ed6` | Eager metadata fix for AITER EAGLE draft extend |
| InferenceX | [#2737](https://github.com/SemiAnalysisAI/InferenceX/pull/2737) | `7c60df6b814db34eeed08db2fe9769305299eeac` | MI355X Qwen 3.5 v0.5.18 recipe and runtime retuning |

## Open changes required by the new frontier

The original accepted C12/maxrun-4 result is a runtime scheduling change on the
merged stack and requires no additional SGLang or AITER patch.

The new low-concurrency points use three open upstream changes:

| Project | PR | Benchmarked head | Live head on 2026-09-02 | State | Role |
|---|---|---|---|---|---|
| SGLang | [#35872](https://github.com/sgl-project/sglang/pull/35872) | `6ac718f05f067214368460ce93d9b19f5c889f5b` | `5bf2a9e7a778e29fb8be6c4cdf27707f02d8af74` | open | Split argmax for ROCm EAGLE top-k-1 draft decode and draft extend |
| SGLang | [#37465](https://github.com/sgl-project/sglang/pull/37465) | `766c02152d5a041d5b4e1a61fdd8691e1bd7515f` | `766c02152d5a041d5b4e1a61fdd8691e1bd7515f` | open | SGLang integration for AITER MTP verify attention |
| AITER | [#5190](https://github.com/ROCm/aiter/pull/5190) | `8fb158c83a53e14c49e825423211620466eb103a` | `b2826f145a146f2fdbdcfee0b6388a6de85f4767` | open | gfx950 assembly MTP verify-attention kernel |

SGLang #35872 and AITER #5190 moved after the benchmarked heads. The accepted
performance claim remains tied to the checksum-pinned overlays in `patches/`;
the newer live heads are not silently substituted and require their own
current-head validation before claiming equivalent performance.

The benchmark inputs are:

```text
d797f195a7a9bbe499499c2ff031e22cb5bab158e37a2865eef330ff9d402ac3  sglang_pr35872_pr37465_combined_instrumented.patch
10e66d269d043f502fd966735f66791beb40195bea01569bfa73d02eeb1c0a09  aiter_pr5190_mtp_verify_attn_asm.patch
```

The instrumentation adds one-time route markers used to prove that both draft
top-k-1 phases and the AITER verify-ASM path were exercised.

## PR action

No new SGLang or AITER PR is required for the accepted optimization: the
functional changes already have upstream PRs #35872, #37465, and #5190.
Reproduction remains patch-based until they merge. The appropriate follow-up is
to validate the current heads and help those existing PRs land, rather than
submit duplicate implementations.

The higher-throughput TP2/EP2 points in the Pareto artifact also use a validated
external AITER FMoE tuning CSV for the 256-expert/top-k-9 path. That is
configuration data rather than source code. A separate data-only AITER
submission would improve out-of-box reproducibility of those historical points,
but it is not required for the completed low-concurrency 20% aggregate
objective.
