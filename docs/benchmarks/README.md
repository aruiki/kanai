# Benchmark receipts

These receipts are reproducible development observations, not release
promises. They are kept separate from AI-quality claims.

## Mozc bridge

Build the pinned bridge, then run:

```sh
python3 scripts/benchmark-mozc-bridge.py \
  --sessions 8 \
  --iterations 20 \
  --output /tmp/mozc-bridge.json
```

The harness starts one real bridge child, opens independent sessions, performs
interleaved real conversions, records p50/p95/p99/max latency, and records the
child RSS when available. It does not start an AI model and is not a Windows
TSF key-to-preedit benchmark. The checked-in
`mozc-bridge-linux-wsl.json` receipt records one WSL/Linux observation; rerun
the command on the release Windows x64 host before using a number as a release
threshold.
