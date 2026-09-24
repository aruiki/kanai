# KanaAI development directive

**Status:** active

KanaAI development proceeds at full power and remains continuous until the
current native Windows TSF milestone is resolved. Waiting for an agent or a
convenient idle state is not a development strategy; completed work is
integrated directly into the main working tree and verified.

## Continuation rule

A milestone or successful check is not a stopping point. After every checkpoint,
continue directly to the next incomplete implementation task. Progress updates
are commentary-only; a final response is reserved for actual completion or a
real blocker. The background loop is a watchdog and recovery mechanism, not a
replacement for implementation work.


1. Build the first usable Windows beta on the pinned upstream Mozc Windows TIP.
2. Keep Rust responsible for broker, session/generation state, bounded local AI,
   learning, privacy, caching, and recovery.
3. Keep Mozc C++ responsible for its mature conversion, dictionary, client/server,
   and TSF behavior; do not create a parallel replacement engine.
4. Use TypeScript only for the development lab, never as the production IME.
5. Do not call a Workbench, HTTP service, bridge, source skeleton, compile-only
   DLL, or unregistered TIP a beta.
6. Keep the local model off the blocking per-key path; every model timeout,
   malformed response, stale generation, or absent model falls back to Mozc.
7. Measure quality against a pinned Mozc baseline and real Windows application
   tests; do not claim Google Japanese Input or ATOK parity without evidence.
8. Report progress at each meaningful checkpoint with percentage, evidence,
   blockers, and the next action.
9. After Phase 1, continue the measured quality loop: error analysis, local
   policy improvement, latency work, regression tests, and real application
   validation.
10. Never hide a failed build, security limitation, missing dependency, or
    unverified runtime behind a successful source-only check.

The detailed gate weights and current percentage are maintained in
[`PROGRESS.md`](PROGRESS.md).
