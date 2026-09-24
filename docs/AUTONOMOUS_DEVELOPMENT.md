# Continuous development loop

KanaAI has a repeatable development loop for the native TSF Phase 1 effort.
It is intentionally a **verification and checkpoint loop**, not a blind
self-rewriting agent: it never commits, pushes, edits source, disables a
failing test, or changes Windows security policy.

## Run once

```sh
npm run development:loop -- --once
```

## Run continuously with automatic recovery

```sh
npm run development:supervisor -- --interval-ms 60000 --max-cycles 0
```

The supervisor starts the verification loop, writes heartbeats, restarts it
after a crash/exit, and terminates/restarts a child whose heartbeat becomes
stale. It never edits source or changes a failing check. Use
`--stale-ms 900000` (the default) for long Windows/Mozc commands.

Detached WSL/Windows-host form:

```sh
mkdir -p .development-loop
nohup npm run development:supervisor -- --interval-ms 60000 --max-cycles 0 \
  > .development-loop/supervisor.log 2>&1 < /dev/null &
echo $! > .development-loop/supervisor.pid
```

Inspect `.development-loop/supervisor-state.json` and
`.development-loop/state.json` for recovery status. Stop the supervisor and its
child with `SIGTERM`/`Ctrl-C`; the next start resumes from a fresh heartbeat
without losing the prior log.

## Run detached on the WSL/Windows host

```sh
nohup npm run development:loop -- --interval-ms 60000 --max-cycles 0 \
  > .development-loop/nohup.log 2>&1 &
echo $! > .development-loop/pid
```

The loop writes ignored local state to:

- `.development-loop/state.json` — latest machine-readable checkpoint;
- `.development-loop/loop.log` — append-only cycle summaries.

## What each cycle checks

- Git whitespace/errors;
- Rust formatting, Clippy, and workspace tests;
- web tests and production build;
- Japanese product-page validation;
- offline Mozc/local-AI quality and fallback evaluation.

The loop records failures and continues. The active developer or coding agent
must inspect the failing command, make the smallest reviewed fix, and return to
the loop. This prevents a failed Windows/TSF boundary from being hidden by an
automatic retry or an unreviewed source mutation.

## Windows-native follow-up

The loop is platform-neutral. The native TSF build and smoke harness remain
explicit Windows-side commands because they require MSVC, Windows SDK, Bazel,
TSF registration, and a real desktop host. Their results must be recorded in
[`PROGRESS.md`](PROGRESS.md) before a release claim is made.
