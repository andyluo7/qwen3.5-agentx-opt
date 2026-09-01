# Upstream status

Status was rechecked on 2026-09-01.

## Merged work used by the campaign

| Project | PR | Merge commit | Role |
|---|---|---|---|
| SGLang | [#36330](https://github.com/sgl-project/sglang/pull/36330) | `c967cd19b56be8efed19e801357d437b5c1fe34c` | Qwen 3.5 MTP unified-attention optimization on gfx950 |
| SGLang | [#36758](https://github.com/sgl-project/sglang/pull/36758) | `acc918b3ece60af20321612b8ad204bdba8fcb80` | ASM FMHA chunked-prefill context attention |
| SGLang | [#36852](https://github.com/sgl-project/sglang/pull/36852) | `36afd70f9c064de4bbf552100b0dc91ee882c80d` | Token-level KV-index fix for AITER ASM context prefill |
| SGLang | [#36915](https://github.com/sgl-project/sglang/pull/36915) | `7f2ee22b70a755d82591d08388c7960f71d32ed6` | Eager metadata fix for AITER EAGLE draft extend |
| InferenceX | [#2737](https://github.com/SemiAnalysisAI/InferenceX/pull/2737) | `7c60df6b814db34eeed08db2fe9769305299eeac` | MI355X Qwen 3.5 v0.5.18 recipe and runtime retuning |

## Patch requirement

The accepted TP2/EP1 C12 result requires no additional SGLang source patch and
no AITER source patch. It is produced by runtime scheduling configuration on
the frozen merged stack: `max-running-requests=4` while retaining decode graph
capacity 24.

The higher-concurrency TP2/EP2 optimized points in the Pareto artifact used an
external validated AITER FMoE tuning CSV for the 256-expert/top-k-9 path. That
is configuration data, not a source-code patch. A later data-only AITER PR is
recommended so those points can be reproduced out of the box; it is not needed
for the headline C12 result.
