# AI implementation: work order, evidence and current state

The authoritative record of the local AI implementation. `STATE.md` is the chronological log and is where
corrections are recorded in the order they happened; this file is where the current state is stated once, so
that a reader does not have to reconstruct it from the log.

Everything below is measured on the implementation host against the **installed** payload at
`C:\Program Files\KanaAI\ai`, not against a staging tree. Every number carries the file that recorded it.

---

## 1. The defect this work existed to fix, and its state

**The supply-path contradiction.** `crates/kanai-broker/src/bin/kanai-broker/installed_ai.rs` required
`<exe>\ai\manifest-v1.json` and `<exe>\ai\STAGING-RECEIPT.json` with `?`, while
`scripts/build-windows-installer.ps1` throws if either is put in the MSI payload and only copies them to
staging. The consequence on the implementation host was one `manifest unavailable or oversized` line and
then Mozc baseline forever, so the recorded "AI integration complete" was false.

**User decision D-7, implemented.** The launch plan is derived at build time from the pinned constants and
embedded in the binary, with no manifest and no receipt. `local_runtime.rs` separates verification from
generation, and a unit test asserts the pure function agrees with the previous JSON path.

**Startup byte verification: performed, and stated in both the code and this repository's docs.** See
`LOCAL_AI.md`, "Startup byte verification", and `crates/kanai-broker/src/bundle_verify.rs`.

**Measured outcome:** the AI starts. The runtime launches from the embedded plan, the model loads from
pinned bytes, and it answers every prompt. What remains broken is the IME, not the AI - see section 4.

---

## 2. Work order and status

The order is serial and was not skipped. Each row states what was measured, not what was intended.

| step | what it was for | state | evidence |
|---|---|---|---|
| **AI-0** | re-measure the starting point | done | 8 commands, exit 0, see section 3 |
| **AI-1** | red regression test for the supply path | done | `platform/windows-tsf/installer/package/tests/Test-AiBrokerPayloadContract.ps1` |
| **AI-2** | separate verification from generation | done | `local_runtime.rs`, unit-tested against the JSON path |
| **AI-3** | D-7 implemented | done | launch plan embedded; no manifest, no receipt |
| **AI-4** | residual defects, red to green | done | F1 TOCTOU, H-2 non-ASCII `%TEMP%`, H-3 deadline, two `#[ignore]` |
| **AI-5** | re-pin the broker digest, AI-bundled build | done | installed broker SHA-256 `D832612E…A0CC`; AI-1 green |
| **AI-6** | real-machine evidence | **6 of 7 done** | section 4 |
| **AI-7** | quality measurement on a held-out corpus | done, **negative** | section 5 |

---

## 3. Commands

The eight gate commands, all expected to exit 0:

```
cargo test -p kanai-broker --lib
cargo test -p kanai-broker --bins
cargo test --workspace
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
powershell -NoProfile -ExecutionPolicy Bypass -File platform/windows-tsf/installer/package/tests/Test-AIRuntimeStaging.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File platform/windows-tsf/installer/package/tests/Test-InstallerBuildScript.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File platform/windows-tsf/installer/package/tests/Test-AiBrokerPayloadContract.ps1
```

Last recorded run: **217 passed, 0 failed, 0 ignored**, all eight exit 0, clippy and fmt clean.

The evidence tests are **gated, not ignored**. They print `KANAI_AI_EVIDENCE=NOT-PERFORMED` and return
unless `KANAI_AI_EVIDENCE=1` is set, so a log always states which happened. To run them against the
installed payload:

```
set KANAI_AI_EVIDENCE=1
set KANAI_AI_INSTALL_ROOT=C:\Program Files\KanaAI\ai
set KANAI_AI_STAGING_ROOT=C:\Program Files\KanaAI\ai
cargo test -p kanai-broker --test rerank_deadline    -- --nocapture --test-threads 1
cargo test -p kanai-broker --test fallback_matrix    -- --nocapture --test-threads 1
cargo test -p kanai-broker --test ai_decision_probe  -- --nocapture --test-threads 1
cargo test -p kanai-broker --test ai_runtime         -- --nocapture --test-threads 1
```

The installed-payload root is named by `KANAI_AI_INSTALL_ROOT`. The repository lives under a
Japanese path, and the pinned runtime refuses a non-ASCII command line, so the evidence tests reach the
staged bytes through an ASCII junction and write keys to a separate ASCII root. The helpers in
`tests/evidence/mod.rs` print which basis was used, so a number cannot be read without knowing whether it
came from an installed product or a staging tree.

---

## 4. AI-6: real-machine evidence

| item | measurement | evidence file |
|---|---|---|
| AI launch receipt | runtime starts from the embedded plan, model loads, loopback endpoint and bearer token issued; reproduced twice | `.local/ai6-logs/installed-runtime-evidence.txt` |
| p50 / p95 / p99 | **1270 / 1347 / 1347 ms**, 8 of 8 applied within the deadline | `.local/ai6-logs/rerank-latency-distribution.txt` |
| working set | **1681.9 MB** working set, 840.4 MB private | `.local/ai6-logs/ai-working-set-and-egress.txt` |
| egress | 1 peer, **all loopback**; 0 non-loopback in 30 samples | same |
| fallback, five classes | 6 rows measured; Mozc order and `adopted=false` on every one; non-vacuity demonstrated by inverting the central claim and watching all 6 rows go red | `.local/ai6-logs/fallback-matrix.txt` |
| **secure-field stop** | `Skipped` / `SecureField` in **35 microseconds** against 1.504 s for an ordinary field on the same live runtime - **42,964x** - which is the evidence the model is never consulted | `.local/ai6-logs/…` (the `a_secure_field_is_refused_before_the_model_is_ever_asked` test) |
| **candidate diff, AI ON vs OFF** | **not measured, and genuinely blocked** | below |

**The one open AI-6 item, and why it cannot be measured here.** The installed `mozc_tip64.dll` faults
while being created:

```
CoCreateInstance  on the TIP CLSID      -> 0x80040154 CLASS_E_CLASSNOTAVAILABLE
DllGetClassObject on the same CLSID     -> S_OK, a class factory
IClassFactory::CreateInstance           -> STATUS_ACCESS_VIOLATION (0xC0000005)
```

Windows recorded the same fault independently: Application Error 1000, faulting module
`mozc_tip64.dll`, faulting offset `0x17E580`. The installed DLL is byte-identical to all four staged
copies under `.local/` (SHA-256 `5BE0B94F…A47D`), so a stale artifact is excluded and the fault is in the
build. Disassembly without a PDB localises it to a CRT comparison routine dereferencing an invalid first
argument, reached from the class factory's `CreateInstance` through virtual dispatch during construction.
Only the symbol and source line are missing, and they are needed to **fix** it, not to describe it.

The consequence is that **no text service can be created, so no process ever loads the TIP, so the IME
never receives a keystroke**: a canary `kanaai` typed into a rich edit commits as the raw characters
`anaai`, with `ime.open` false in 30 of 30 samples. There is no conversion, so there is nothing to diff
between AI on and AI off.

**This is a build defect on the critical path of any release.** A text service that cannot be created is
not a working IME, however well the AI path behaves.

---

## 5. AI-7: quality, measured and negative

Every role the code or the product could give the pinned `qwen2.5-1.5b-instruct-q4_k_m` was measured by
asking the real runtime through the real prompt machinery. The instrument is
`crates/kanai-broker/tests/ai_decision_probe.rs`.

| role | measurement | verdict |
|---|---|---|
| candidate rerank | top-1 **0 of 6** | unusable |
| kana to kanji conversion | exact **2 of 12** | unusable |
| reading generation | exact **5 of 15** | not shippable |
| error flagging, as a hint | 5 of 8 caught, **2 of 8 false positives** | not shippable |
| error flagging, as a pointer | **0 of 5** located | not shippable |
| slow-path clause completion | **3 of 6 empty**, 1 of 6 not reproducible | not shippable |

The failure modes are specific. On conversion the dominant failure is **echoing the input kana or the
surrounding context** rather than answering. On flagging the model finds slips that leave the text
ungrammatical and misses conversions that produce a fluent sentence with the wrong word, and it cannot say
*where*: the character offsets it returned were almost all `0`. The self-reported `confidence` that
`map_decision` uses as its adoption gate **carries no information about correctness** - 0.9 was attached to
every wrong answer and to no right one.

**This is a statement about the weights, not the plumbing.** The supply path is fixed, the runtime starts,
the model loads from pinned bytes, and it answers. Nothing here predicts what a different weight would do,
and nothing here is a statement about local models in general.

**Not claimed anywhere above:** no comparison against Mozc, because the text service cannot be created and
Mozc's own output is therefore unobtainable. Every rate is absolute, against a judgement, from small
hand-written corpora whose synthetic misspellings are invented rather than observed.

---

## 6. Open items, and the two decisions

**Open item.** The candidate diff is the only AI-6 measurement this host cannot produce, and it needs the
TIP fixed first.

**Two decisions, both the user's, neither made silently here:**

1. **Which weight to ship.** With the pinned one there is no AI strength to ship. Shipping the Mozc IME
   with the AI stage off is exactly the published `v0.1.0-beta.1` and contradicts nothing measured above.
   Changing the weight means re-running the six measurements, which are written and gated.
2. **Whether to install LLVM/clang-cl** so the TIP can be rebuilt with symbols. The tree's `windows_env`
   config expects clang-cl and it is not installed; MSVC is installed and Bazel 9.0.2's MSVC autodetection
   fails on this host for a reason not yet identified, even though all six tools and the Windows SDK are
   present and `vswhere` resolves the installation correctly.
