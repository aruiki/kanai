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

## Measured quality verdict for the pinned weight: no role works

The paragraph above says the pinned bundle is "an implementation candidate, not evidence of Japanese IME
quality". It has since been **executed against the installed payload on the implementation host**, and
the quality question it deferred is now answered. Every role the code or the product could give the
pinned `qwen2.5-1.5b-instruct-q4_k_m` was measured by asking the real runtime through the real prompt
machinery:

| role | measurement | verdict |
|---|---|---|
| candidate rerank | top-1 **0 of 6** ranked cases | unusable |
| kana to kanji conversion | exact **2 of 12** | unusable |
| reading generation (furigana) | exact **5 of 15** | not shippable |
| error flagging, as a hint | 5 of 8 caught, **2 of 8 false positives** | not shippable |
| error flagging, as a pointer | **0 of 5** located the error | not shippable |
| slow-path clause completion | **3 of 6 empty**, 1 of 6 not reproducible | not shippable |

**None of the six works.** The failure modes are specific rather than diffuse, and they matter for
choosing what to do next:

* On conversion the dominant failure is not a wrong guess but **echoing the input kana or the surrounding
  context back** - 7 of 12 cases. It completes the shape of the answer rather than doing the conversion.
* On flagging the model finds slips that leave the text ungrammatical and **misses conversions that
  produce a fluent sentence with the wrong word**, which is the hard class. It cannot say *where*: the
  character offsets it returned were almost all `0`.
* The self-reported `confidence` that `map_decision` uses as an adoption gate **carries no information
  about correctness** - 0.9 was attached to every wrong answer and to no right one.
* Two roles that would have been safe are still not reproducible between identical calls at
  `temperature: 0`.

**This is a statement about the weights, not about the plumbing.** The supply path is fixed, the runtime
starts from the embedded launch plan, the model loads from pinned bytes, and it answers every prompt. It
is not a statement about local models in general or about llama.cpp, and nothing here predicts what a
different weight would do.

**What follows.** The latency numbers in this document are real and reproducible; the quality numbers
above are the reason the AI path is not yet a product feature. Shipping the Mozc IME with the AI stage
off is coherent with everything measured here. Shipping a different weight means re-running these same
six measurements, which are written as gated tests in
`crates/kanai-broker/tests/ai_decision_probe.rs`: they print `KANAI_AI_EVIDENCE=NOT-PERFORMED` unless
`KANAI_AI_EVIDENCE=1` is set, so a new model is measured by the same instrument rather than by a fresh
argument.

**Corpora.** Every rate above comes from a small hand-written corpus, and the flags are synthetic
misspellings invented to be the kind a kanji-selection or mixed-script slip produces - they are not
observed user errors. **No comparison against Mozc is claimed anywhere above**, because on this host the
text service cannot be created and Mozc's own output is therefore unobtainable; the rates are absolute,
measured against the reading a Japanese speaker would give.

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
- LLM: never blocks key input. **The rerank deadline is 1500 ms, not 250 ms.**
- Timeout: keep the Mozc/FastRanker result and mark the AI result stale.
- Cache: key by model revision, reading, normalized context, candidate IDs, and relevant learning version.
- Thermal/low-battery: suspend optional model work and keep the IME usable.

### The 250 ms figure was a target, and measurement moved it

An earlier revision of this line said "p95 target is approximately 250 ms for rerank where
hardware permits". That number is not achievable with the pinned weight on the implementation host, and
the code no longer uses it. Measured against the **installed** payload on that host, with eight real
CPU inferences per run:

| measurement | value |
|---|---|
| warm p50 | **1270 ms** (a second run: 1151 ms) |
| warm p95 | **1347 ms** (a second run: 1163 ms) |
| warm p99 / max | **1347 ms** (a second run: 1179 ms) |
| raw warm samples, ms | `[1326, 1256, 1267, 1270, 1347, 1261, 1270, 1302]` |
| requests applied within the deadline | **8 of 8** |
| first completion after startup | **1680-1916 ms**, over the deadline every run |
| deadline the code now ships | 1500 ms (`MAX_ENHANCEMENT_DEADLINE_MS` is 2000 ms, the protocol cap) |

So the shipped 1500 ms is a measurement rather than a preference: the warm p99 sits about 150 ms inside
it and 8 of 8 requests were delivered. **The 250 ms value was a key-path budget applied to a request
that is not a key-path request**, and every conversion at that budget paid a full CPU inference and then
discarded the answer. That was defect H-3; the deadline moved and the reason is recorded here so the
number is not re-introduced.

**Two things the deadline does not fix, both measured.** The first completion after startup costs
1680-1916 ms because it pays the prefill of a realistic reading, so **every conversion until the model
is warm falls back to the Mozc baseline.** A one-token warm-up was tried and measured: it completes in
about 0.1 s and leaves the first rerank at 1884 ms, no better than without it, because the cost is the
prefill and not the first inference. And the rerank is **not reproducible run to run** - two runs of the
same corpus at `temperature: 0` produced different orderings, which is a consistency problem of its own
for something that reorders the user's candidates.

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

## Launch plan: embedded at build time (user decision D-7)

The broker used to read `ai\manifest-v1.json` and `ai\STAGING-RECEIPT.json` at
startup and fail when either was absent. The installer deliberately refuses to
make either one an MSI payload file, so on every real install both reads failed,
the AI never started, and every conversion silently stayed on the Mozc
baseline. Each side passed its own tests.

The launch plan is now derived at build time from the pinned constants, with no
document read:

| plan item | source |
|---|---|
| `model_path` | `model/` + the pinned weight file name |
| `server_path` | `runtime/` + `llama-server.exe` |
| `api_key_file_path` | caller-supplied, per-process |
| `host` | constant `127.0.0.1` |
| `port`, `context_size` | caller-supplied, bounded |
| `parallel` = 1, `device` = `none`, `gpu_layers` = 0, `no_ui` = true | fixed launch policy |

The document-based path still exists and is still tested, and a unit test asserts
the two derivations produce the same two paths, so embedding the plan cannot
quietly become a different launch.

## Startup byte verification: performed, and what it does not prove

Because the plan is embedded, nothing on this machine was being checked. The
verification moved to startup, where file access belongs
(`kanai_broker::bundle_verify::verify_pinned_bundle`), and it **is performed**.

**Verified**, against the pinned constants:

- the model weight exists, is exactly 1,117,320,736 bytes, and has SHA-256
  `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`;
- the runtime closure is a flat directory of regular files, has exactly 51
  entries, and its ordinal-sorted name list hashes to
  `68da91a595ea841f87c7f7f34aff23bdf0a9910f129cf0fd3a06264205b61f0c`;
- `THIRD-PARTY-NOTICES.txt` matches its pinned size and digest;
- both licence texts are present, regular, and non-empty.

**Not verified**, stated so that no report overstates it:

1. **The bytes of the 51 runtime closure entries.** The only record of their
   digests is the staging receipt, and the installer refuses to ship it. What is
   checked is the closure's *composition*, so a missing, added, or renamed entry
   is rejected, but the content of a correctly named entry is not proved.
2. **The broker executable's own bytes.** An executable cannot pin its own digest
   without a hash fixed point; that identity is bound by the MSI, which carries a
   recorded SHA-256 for `kanai-broker.exe`.

**Measured cost** (implementation host, staged real bundle, warm page cache,
`cargo test --release`, four runs): **0.622 / 0.589 / 0.590 / 0.591 seconds** for
the 1.04 GiB weight plus the notice, about 1,805 MB/s. A debug build of the same
code takes 22.153 s, which is not the shipped cost and is recorded only so the
two are not confused. A cold page cache was not measured, so no cold-start figure
is claimed.

The cost is paid once, on the AI slow path's startup. No model work, and no
hashing, is reachable from a key-input handler.

This is not yet product evidence. The AI has not been observed running on an
**installed** build, and the AI-bundled MSI has not been rebuilt since this change.
What has been observed is the production code path on the development machine
against the real 1.04 GiB weight and the real `llama-server.exe`, over loopback.

## The request is sent on the socket whose ownership was proved

`RuntimeOwnership::verify_endpoint` used to open a connection, prove that
connection, and then let the HTTP client open a *different* one. The window
between the proof and the bytes was not closed, and a port that changed hands in
that window would have received the bearer token, the preedit, and the candidate
text.

The proof now happens on the request's own socket:

1. connect to the loopback endpoint;
2. read that socket's own `(local, peer)` pair;
3. prove, through the operating system's TCP connection table, that the server end
   is the child this broker started;
4. only then write the request.

A refusal at step 3 writes nothing at all, so an unproven listener receives no
socket - not merely no request. The
`a_request_is_never_forwarded_to_an_endpoint_the_broker_cannot_name` test in
`bin/kanai-broker` asserts that, and it **fails** if the old
verify-then-reconnect shape is put back.

**What this still does not prove**: an ownership change *after* the bytes are
written. Those bytes cannot be recalled. What is excluded is the race *before* the
write.

The loopback transport is written out rather than delegated to an HTTP client,
because a client that "might" add a proxy hop, a redirect, or a connection pool is
not something this path can reason about. It accepts all three HTTP/1.1 body
framings (`chunked`, `Content-Length`, end of stream) and bounds the head at
16 KiB, the body at 64 KiB, and the whole exchange at 2 s.

## The key file root has to be ASCII, and used not to be

The key file's path is part of the runtime's command line, and the pinned runtime
is refused rather than started when that command line is not ASCII. The key file
cannot live under the install root (`C:\Program Files` is not writable by a
non-elevated account), so it goes under the user's temporary directory - which,
for a Japanese account name, is `C:\Users\<name>\AppData\Local\Temp` and is not
ASCII. On such a machine the AI path was off permanently, and nothing in a log
said why.

Windows can name the same directory by its 8.3 short name, which is ASCII, so the
short form is preferred and the long form is used only when it is already ASCII.
`kanai_broker::key_root` resolves the first candidate that is ASCII *and* that the
account can create a private directory in, and reports `NoAsciiRoot` or
`NotCreatable` by name when none qualifies. The key file's own protection is
unchanged: the directory that actually holds the key is still created by the key
writer with a protected owner-only DACL, and the probe that tests writability
takes its own directory straight back out, so it cannot leave a
wrongly-permissioned one behind.

This was not reproducible on the implementation host, whose account name is ASCII.
It is fixed by construction and covered by a test that injects a Japanese account's
temporary directory.

## The rerank deadline is 1500 ms, and that is a measurement

The deadline was 250 ms, which is a key-path budget. The pinned weight on this
machine's CPU answers a rerank in around 1.1-1.3 s, so every request paid the whole
cost - inference, the bearer token, the user's preedit and candidate text - and the
coordinator's timeout then discarded the answer and returned the Mozc order
unchanged. A rerank that can never arrive is a cost with no result.

Measured on the implementation host, on the production request path
(`tests/rerank_deadline.rs`, 8 samples):

| deadline | outcome |
|---|---|
| 250 ms | `TimedOut`, order unchanged, nothing adopted |
| 1500 ms | 8 of 8 `Applied`, p50 1110 ms, p95 1137 ms, p99 1137 ms |

The rerank is dispatched as an asynchronous job and applied only while the session,
generation and admission epoch still match, so the longer budget costs a background
wait rather than a stalled key handler. It stays under the protocol's
`MAX_ENHANCEMENT_DEADLINE_MS` cap of 2000 ms, and the test fails if the observed p99
stops fitting inside the shipped value.

**What this does not fix**: in that same run the model changed the order **zero**
times (`changed_positions=0`, `adopted=0`). "Applied" means the decision was
delivered, not that it was better. Quality is a separate question and is not
answered by a latency fix.

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
