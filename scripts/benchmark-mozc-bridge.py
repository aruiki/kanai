#!/usr/bin/env python3
"""Measure the bounded KanaAI Mozc bridge with real child-process I/O.

This is deliberately a bridge/conversion benchmark, not an AI-quality or
Windows-release benchmark. It uses the same tab-separated UTF-8 protocol as
``kanai-mozc`` and writes a machine-readable JSON receipt when requested.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import statistics
import subprocess
import tempfile
import time
from urllib.parse import quote


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_BRIDGE = ROOT / "third_party/mozc/src/bazel-bin/kanai/kanai_mozc_bridge"
# Session 0 is the compatibility session created at bridge startup, so the
# explicit benchmark sessions must remain below the 64-session upstream cap.
MAX_EXPLICIT_SESSIONS = 63
MAX_ITERATIONS = 10_000


def encode(value: str) -> str:
    return quote(value, safe="-._~")


def read_response(process: subprocess.Popen[str]) -> dict[str, object]:
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("Mozc bridge closed stdout")
    response = json.loads(line)
    if not response.get("ok"):
        raise RuntimeError(str(response.get("error", "bridge request failed")))
    return response


def request(process: subprocess.Popen[str], command: str) -> tuple[float, dict[str, object]]:
    started = time.perf_counter()
    process.stdin.write(command + "\n")
    process.stdin.flush()
    response = read_response(process)
    return (time.perf_counter() - started) * 1000.0, response


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, int((len(ordered) - 1) * fraction))
    return ordered[index]


def rss_kib(pid: int) -> int | None:
    status = pathlib.Path(f"/proc/{pid}/status")
    if not status.is_file():
        return None
    for line in status.read_text(encoding="utf-8").splitlines():
        if line.startswith("VmRSS:"):
            fields = line.split()
            return int(fields[1])
    return None


def run(args: argparse.Namespace) -> dict[str, object]:
    bridge = pathlib.Path(args.bridge).expanduser().resolve()
    if not bridge.is_file():
        raise RuntimeError(
            f"Mozc bridge not found at {bridge}; build //kanai:kanai_mozc_bridge first"
        )
    if not 1 <= args.sessions <= MAX_EXPLICIT_SESSIONS:
        raise RuntimeError(
            "explicit sessions must be between 1 and "
            f"{MAX_EXPLICIT_SESSIONS} (session 0 is the compatibility session)"
        )
    if not 1 <= args.iterations <= MAX_ITERATIONS:
        raise RuntimeError(f"iterations must be between 1 and {MAX_ITERATIONS}")

    with tempfile.TemporaryDirectory(prefix="kanai-mozc-benchmark-") as profile:
        process = subprocess.Popen(
            [str(bridge), f"--profile={profile}"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        latencies: list[float] = []
        try:
            for session_id in range(1, args.sessions + 1):
                request(process, f"open\t{session_id}")
            for generation in range(1, args.iterations + 1):
                for session_id in range(1, args.sessions + 1):
                    elapsed, response = request(
                        process,
                        "convert\t{}\t{}\t\t\t{}".format(
                            session_id, encode(args.input), generation
                        ),
                    )
                    if not response.get("candidates"):
                        raise RuntimeError(f"session {session_id} returned no candidates")
                    latencies.append(elapsed)
            end_rss = rss_kib(process.pid)
            request(process, "shutdown")
        finally:
            if process.stdin:
                process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    return {
        "bridge": str(bridge),
        "sessions": args.sessions,
        "iterationsPerSession": args.iterations,
        "totalConversions": len(latencies),
        "latencyMs": {
            "p50": round(statistics.median(latencies), 3),
            "p95": round(percentile(latencies, 0.95), 3),
            "p99": round(percentile(latencies, 0.99), 3),
            "max": round(max(latencies), 3),
        },
        "bridgeProcessCount": 1,
        "rssKibAtEnd": end_rss,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bridge",
        default=os.environ.get("KANAI_MOZC_BRIDGE", str(DEFAULT_BRIDGE)),
        help="path to kanai_mozc_bridge",
    )
    parser.add_argument("--sessions", type=int, default=8)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--input", default="kyou")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    result = run(args)
    encoded = json.dumps(result, sort_keys=True, indent=2)
    print(encoded)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"benchmark-mozc-bridge: FAIL: {error}", file=os.sys.stderr)
        raise SystemExit(1)
