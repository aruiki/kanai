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


## Pinned first-bundle candidate (approved for implementation, not yet product evidence)

The user approved the following first AI bundle candidate for A2 implementation:

- **Model:** `Qwen/Qwen2.5-1.5B-Instruct-GGUF`, revision `91cad51170dc346986eccefdc2dd33a9da36ead9`
- **Weight:** `qwen2.5-1.5b-instruct-q4_k_m.gguf`, 1,117,320,736 bytes, LFS SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`
- **Weight license:** Apache-2.0; the full license and attribution notice must ship with the bundle
- **Runtime:** `ggml-org/llama.cpp` release `b11146`, commit `7fe450e19305b828c199d602c23a8337aaa1f03b`
- **Windows CPU asset:** `llama-b11146-bin-win-cpu-x64.zip`, 18,560,055 bytes, SHA-256 `14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1`
- **Runtime license:** MIT; dependency notices and the final SBOM remain required

The Qwen weight has now been downloaded and hash-verified locally, but has not
been installed into KanaAI or executed as part of the product. The pinned
llama.cpp runtime archive has also been downloaded and inspected separately:
it is 18,560,055 bytes, SHA-256
`14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1`,
and contains 51 pinned entries including `llama-server.exe`,
`llama-server-impl.dll`, `llama-common.dll`, CPU `ggml` DLLs, `libomp.dll`,
`mtmd.dll`, and `LICENSE-LLVM-OpenMP`. Neither input has been executed as
part of the product. The complete installer is expected to be about 1.1 GB.
This is an implementation candidate, not evidence of Japanese IME quality,
latency, memory use, crash recovery, or completed licensing review. The older
third-party `unsloth/Qwen3-1.7B-GGUF` artifact is not part of the release
candidate.

## Roles and model classes

| Runtime class | Suggested model class | Use | Memory target |
|---|---|---|---:|
| `MozcOnly` | none | composition, conversion, local learning | 0–256 MiB application data |
| `FastRanker` | small classifier / embedding model | candidate feature scoring | model-dependent, target <1 GiB working set |
| `Tiny` | Qwen3 0.6B Q4 or equivalent | short ambiguity and repair prompts | 1–2 GiB working set |
| `Compact` | Qwen3 1.7B Q4 or equivalent | semantic rerank, patch, explicit rewrite | 2–4 GiB working set |
| `Balanced` | Qwen3 4B Q4 or equivalent | long-form explicit assist | 4–6 GiB working set |

Qwen official model repositories are Apache-2.0. GGUF files from third parties are separate artifacts: verify the upstream model license, converter revision, quantization, and SHA-256 before redistribution. Gemma and other model families have separate terms and are not interchangeable license-wise.

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

## Local server integration target

The release candidate is intended to use the pinned `llama-server` executable
and Qwen weight from the manifest above. The production launcher must start it
from the installed sibling directory without user environment variables or a
manually started server. A development-only equivalent is:

```bash
llama-server \
  -m <staged-model-path> \
  -c 2048 \
  -np 1 \
  --host 127.0.0.1 \
  --port <validated-random-port> \
  --no-ui
```

The pinned `b11146` help output was checked on Windows: it provides
`--model`, `--ctx-size`, `--parallel`, `--host`, `--port`, `--api-key-file`,
`--device none`, `--gpu-layers 0`, and `--no-ui`. The production launcher
must use the verified subset and record the actual command identity; this is
not yet wired into the broker.

The Windows runtime must receive an ASCII-safe path for the token file and
model/runtime launch inputs. A controlled smoke test showed that
`llama-server` b11146 exited before startup when `--api-key-file` was placed
under a Unicode staging path, while the same bytes loaded and served a
loopback request through an ASCII path. The product launcher must therefore
use an ASCII-safe protected token location (or a verified short-path
projection) and test this explicitly.

An isolated ASCII-path smoke also loaded the real pinned Qwen weight and
returned a bounded JSON decision with an exact candidate-ID permutation.
This verifies the runtime/format seam only; it is not a Japanese quality
evaluation, TSF integration result, or release gate.

KanaAI then talks only to the authenticated loopback OpenAI-compatible endpoint.
The server must bind to loopback, use a per-process token, disable logging and
network features, and be killed/restarted under a bounded supervisor. Remote
endpoints are rejected unless the user explicitly enables them in a development
build. This target is not yet implemented or packaged.

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
