# Local AI runtime

## Phase 1 TSF quality mode

Phase 1 is a native Windows TSF IME based on the pinned upstream Mozc TIP.
KanaAI adds a fast, bounded local quality layer to Mozc's existing candidates;
it does not make the browser Workbench, CLI, or bridge the product. The normal
path is Mozc first, then a latency-bounded ranker/policy, with optional local
semantic assistance for ambiguity, repair, prediction, or an explicit action.

The quality reference is a mature Japanese IME experience. It is evaluated with
reproducible Japanese cases against the pinned Mozc baseline; Google Japanese
Input's proprietary code, dictionaries, cloud data, and UI are not copied.


## Roles and model classes

| Runtime class | Suggested model class | Use | Memory target |
|---|---|---|---:|
| `MozcOnly` | none | composition, conversion, local learning | 0–256 MiB application data |
| `FastRanker` | small classifier / embedding model | candidate feature scoring | model-dependent, target <1 GiB working set |
| `Tiny` | Qwen3 0.6B Q4 or equivalent | short ambiguity and repair prompts | 1–2 GiB working set |
| `Compact` | Qwen3 1.7B Q4 or equivalent | semantic rerank, patch, explicit rewrite | 2–4 GiB working set |
| `Balanced` | Qwen3 4B Q4 or equivalent | long-form explicit assist | 4–6 GiB working set |

Qwen3 official model repositories are Apache-2.0. GGUF files from third parties are separate artifacts: verify the upstream model license, converter revision, quantization, and SHA-256 before redistribution. Gemma and other model families have separate terms and are not interchangeable license-wise.

## Hardware selection

KanaAI recommends a tier from free system memory and accelerator headroom, not installed VRAM alone:

| Free RAM / usable accelerator memory | Recommended class |
|---|---|
| <2 GiB / <2 GiB | MozcOnly |
| ~2 GiB / ~4 GiB RAM | Tiny or FastRanker |
| ~3 GiB / ~6 GiB RAM | Compact |
| ~6 GiB / ~10 GiB RAM | Balanced |
| Higher headroom | Balanced or user-selected larger model |

The system must measure actual free memory before loading a model. It must not load a second model while a conversion is active, and it must fall back to deterministic ranking on OOM, timeout, low battery, or thermal pressure.

## Latency policy

- Mozc result: returned immediately.
- Fast ranker: asynchronous or bounded to the current generation.
- LLM: never blocks key input; p95 target is approximately 250 ms for rerank where hardware permits.
- Timeout: keep the Mozc/FastRanker result and mark the AI result stale.
- Cache: key by model revision, reading, normalized context, candidate IDs, and relevant learning version.
- Thermal/low-battery: suspend optional model work and keep the IME usable.

## Local server example

For the recommended compact model:

```bash
llama-server \
  -hf unsloth/Qwen3-1.7B-GGUF:Q4_K_M \
  -c 2048 \
  -np 1 \
  --jinja \
  --reasoning off \
  --host 127.0.0.1 \
  --port 8080
```

KanaAI then talks only to:

```text
http://127.0.0.1:8080/v1/chat/completions
```

The server must bind to loopback. Remote endpoints are rejected unless the user explicitly enables them in a development build.

## What is sent to the model

For reranking, the default payload is bounded to:

- current reading;
- up to 32 normalized characters of explicitly approved local context;
- candidate IDs and values;
- selected recent local examples;
- requested action and output schema.

It excludes the clipboard, full document, URL, window title, app path, learning corpus, and unrelated history by default.

For writing assistance, the user sees the exact selected text, instruction, model, and destination before execution. A local result is still previewed before it replaces a selection.

## Quality evaluation

The model is not accepted merely because it writes fluent Japanese. KanaAI's held-out evaluation set measures:

- top-1 and top-5 conversion accuracy;
- mean reciprocal rank;
- ambiguous-homophone accuracy;
- typo-repair precision and abstention rate;
- catastrophic rewrite rate;
- candidate acceptance and undo rate;
- p50/p95 latency and memory working set;
- behavior during timeout, OOM, and process restart.

The model must be able to abstain. A correct `NONE` is better than a plausible but wrong candidate.
