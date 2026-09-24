# Local AI evaluation plan

KanaAI evaluates AI as an IME subsystem, not as a generic chat benchmark.

## Candidate reranking

Build a held-out Japanese set containing:

- homophones with a clear context (`今日/京`, `感覚/ showcased` style pairs);
- technical and business vocabulary;
- personal names and user dictionary collisions;
- sentence fragments and short chat messages;
- inputs with no reliable answer, where abstention is the correct behavior.

Measure:

- top-1 and top-5 accuracy against human-selected Mozc candidates;
- MRR and NDCG over the original candidate set;
- regression rate against deterministic Mozc;
- confidence calibration and abstention quality;
- p50/p95 latency and working-set memory.

The model may return only an existing candidate ID or `NONE`. A free-form candidate is not accepted in the first release.

## Repair

Repair fixtures must distinguish:

- intended typo from a valid but unusual word;
- homophone selection from spelling correction;
- a local user name from a common dictionary word;
- a correction that changes meaning and one that does not.

Every patch is previewed, attributed, and undoable. The model must not rewrite a committed document in the background.

## Writing assistance

Writing fixtures cover formality, concision, bulletization, business tone, and summarization. The UI always shows a preview and an explicit apply action. The model receives only the selected text, instruction, and explicitly approved local style summary.

## Hardware matrix

Run every profile on:

- 2–4 GiB RAM CPU-only machines;
- 4–8 GiB RAM CPU machines;
- integrated GPU machines with limited VRAM;
- discrete GPU machines;
- low-battery and thermally constrained states.

The system must remain usable when the model server is not running. A timeout, OOM, malformed response, or model revision mismatch must preserve the Mozc/FastRanker result.

## Release gate

A model is not promoted to the default local tier until it passes:

1. no regression on deterministic conversion fixtures;
2. acceptable top-1/MRR improvement on the held-out set;
3. catastrophic rewrite rate below the product threshold;
4. p95 rerank latency within the device budget;
5. reproducible model/quantization/license manifest;
6. abstention and stale-generation tests;
7. safe behavior with no history, password fields, and empty context.
