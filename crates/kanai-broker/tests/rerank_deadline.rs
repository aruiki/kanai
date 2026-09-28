//! H-3: the rerank deadline, measured against the real pinned CPU runtime.
//!
//! # The defect
//!
//! `CandidateRerankRequest::new` defaulted `deadline_ms` to 250, and
//! `EnhancementCoordinator` wraps the backend call in a timeout of exactly that
//! value. The pinned Qwen2.5-1.5B Q4_K_M weight on this machine's CPU answers a
//! rerank in around 1.3 s. So every request paid the whole cost - model
//! inference, the bearer token, the user's preedit and candidate text - and the
//! answer arrived after the timeout had already replaced it with the Mozc
//! baseline. The cost was real and the result was discarded.
//!
//! # What this file establishes
//!
//! Three things, in one real run against the real runtime:
//!
//! 1. the **before** case: at 250 ms the coordinator falls back and the model's
//!    work is thrown away;
//! 2. the **after** case: at the deadline this repository now ships, a decision
//!    is delivered rather than discarded;
//! 3. the distribution - p50, p95, p99, and how often the model actually changed
//!    the order - so the shipped deadline is a measurement and not a preference.
//!
//! The threshold this file compares against is `MEASURED_DEADLINE_MS`. If the
//! real runtime stops meeting it, this test fails rather than the number quietly
//! becoming wrong.
//!
//! Gated by `KANAI_AI_EVIDENCE=1`; see `tests/evidence`.

#![cfg(windows)]

mod evidence;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use kanai_broker::ai_runtime::{
    SUGGESTED_READINESS_DEADLINE, reserve_loopback_port, start_embedded_ai_runtime,
};
use kanai_broker::{
    Broker, CancellationToken, Candidate, CandidateRerankRequest, CreateSessionRequest,
    DeterministicBackend, EnhancementCoordinator, EnhancementPolicy, FieldClass, GenerationToken,
    LocalOpenAiBackend, RequestCommand, RequestEnvelope, ResponsePayload,
};

/// The deadline the product ships for a model-backed rerank.
///
/// Chosen from a measured distribution on the implementation host, not from
/// taste: the observed p99 is well inside it and it stays under
/// `MAX_ENHANCEMENT_DEADLINE_MS`. See `docs/LOCAL_AI.md`.
const MEASURED_DEADLINE_MS: u32 = 1_500;

/// The deadline the product shipped before H-3, kept so the "before" case is a
/// measurement rather than an assertion about the past.
const PREVIOUS_DEADLINE_MS: u32 = 250;

/// How many measured reranks the distribution is taken from. Small on purpose:
/// each one is a real CPU inference, and a distribution from 4 samples would be
/// a decoration.
const SAMPLES: usize = 8;

/// One percentile of a sorted sample, nearest-rank.
fn percentile(sorted_millis: &[u128], fraction_num: usize, fraction_den: usize) -> u128 {
    if sorted_millis.is_empty() {
        return 0;
    }
    let rank = fraction_num * sorted_millis.len() / fraction_den;
    sorted_millis[rank.min(sorted_millis.len() - 1)]
}

/// A rerank response, or the encoded response in the panic.
///
/// A bare `expect("a rerank payload")` on a failure envelope tells the reader
/// nothing about *why* the request failed, and "why" is the whole content of an
/// H-3 measurement.
fn decoded_rerank(
    response: &kanai_broker::ResponseEnvelope,
    label: &str,
) -> kanai_broker::CandidateRerankResponse {
    match response.payload() {
        Some(ResponsePayload::RerankCandidates(result)) => result.clone(),
        _ => panic!(
            "the {label} produced no rerank payload: {}",
            kanai_broker::encode_response(response)
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                .unwrap_or_else(|error| format!("<unencodable: {error}>"))
        ),
    }
}

/// The candidates a real rerank sees, so the measurement is not a toy payload.
fn candidates() -> Vec<Candidate> {
    let candidate = |id: u64, text: &str, reading: &str, rank: u16| Candidate {
        id,
        text: text.to_owned(),
        reading: Some(reading.to_owned()),
        rank,
    };
    vec![
        candidate(1, "奇怪", "きかい", 0),
        candidate(2, " Cannade", " cannade", 1),
        candidate(3, "漢字", "かんじ", 2),
        candidate(4, "感じ", "かんじ", 3),
        candidate(5, "監事", "かんじ", 4),
    ]
}

fn request(deadline_ms: u32) -> RequestEnvelope {
    let mut rerank = CandidateRerankRequest::new(9, 0, candidates());
    rerank.deadline_ms = deadline_ms;
    RequestEnvelope::new(2, RequestCommand::RerankCandidates(rerank))
}

fn coordinator_for(backend: LocalOpenAiBackend) -> EnhancementCoordinator<LocalOpenAiBackend> {
    EnhancementCoordinator::with_policy(backend, EnhancementPolicy::LocalQualityOnly)
}

#[tokio::test]
async fn the_shipped_deadline_is_one_the_real_runtime_meets() {
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(
            "the_shipped_deadline_is_one_the_real_runtime_meets",
            "KANAI_AI_EVIDENCE is not set to 1",
        );
        return;
    }
    // The payload root, whichever basis it comes with. This test already starts
    // the runtime through the embedded (D-7) entry point, so pointing it at an
    // installed product is what makes the reported percentiles a statement about
    // the shipped payload rather than about a staging tree. The helper prints
    // which basis was used, so the numbers cannot be read without it.
    let stage = evidence::payload_root_for_measurement();

    // This repository lives under a Japanese path and the pinned runtime refuses
    // a non-ASCII command line, so the staged bytes are reached through an ASCII
    // junction and the key goes to a separate ASCII writable root. That is also
    // how a real install behaves: the payload under Program Files, the
    // per-process secret somewhere the user can write.
    let ascii_install = tempfile::tempdir().expect("an ASCII install root");
    let installed_root = ascii_install.path().join("kanai-ai");
    let _junction = AsciiJunction::create(&installed_root, &stage);
    let ascii_keys = tempfile::tempdir().expect("an ASCII key root");

    // The production entry point, not the document-based one: this is the call
    // the installed broker makes, so the plan, the byte verification and the
    // launch are all the ones that ship.
    let port = reserve_loopback_port().expect("a reserved loopback port");
    let runtime = start_embedded_ai_runtime(
        &installed_root,
        ascii_keys.path(),
        port,
        SUGGESTED_READINESS_DEADLINE,
        &CancellationToken::new(),
    )
    .await
    .expect("the pinned runtime becomes ready through the embedded launch plan");

    let backend = LocalOpenAiBackend::new_with_api_key(
        runtime.base_url(),
        runtime.pinned_model_id(),
        runtime.api_key().expose().to_owned(),
    )
    .expect("a loopback backend for the staged runtime");
    let coordinator = coordinator_for(backend);
    // Held for the whole test: dropping the broker deactivates the session and every
    // later request would come back stale, which has nothing to do with latency.
    let (_session, token) = regular_session();

    // 1. A warm-up, then the steady-state distribution, then the old deadline.
    //
    // The order matters and the reason is a measured property of the pinned
    // runtime: it runs with `--parallel 1`, so a request the coordinator abandons
    // is still being computed by the model afterwards. A 250 ms request therefore
    // does not merely waste its own budget - it delays whatever the user types
    // next. Measuring the deadline with a discarded request in flight would blame
    // the shipped value for the old value's cost, so the warm-up comes first and
    // the old-deadline case comes last.
    // The cold start is probed at the **protocol cap**, not at the shipped
    // deadline, and that choice is the measurement.
    //
    // At the shipped 1500 ms the cold request times out, which says only "more
    // than 1500". Probing at the cap answers the question that decides the fix:
    // if a cold completion fits inside `MAX_ENHANCEMENT_DEADLINE_MS`, a
    // first-request budget of its own is enough; if it does not, then **no
    // deadline the protocol permits can cover a cold start** and the runtime has
    // to warm the model before it reports ready. A larger probe bound is not an
    // option: the request validator rejects any deadline outside 1..=2000, which
    // is itself worth knowing because it bounds every fix available here.
    const COLD_PROBE_BOUND_MS: u32 = kanai_broker::protocol::MAX_ENHANCEMENT_DEADLINE_MS;
    let warmup_latency = Instant::now();
    let warmup = tokio::time::timeout(
        Duration::from_secs(120),
        coordinator.handle(
            request(COLD_PROBE_BOUND_MS),
            token.clone(),
            CancellationToken::new(),
        ),
    )
    .await
    .expect("the warm-up must not hang");
    let cold_elapsed_ms = warmup_latency.elapsed().as_millis();
    let warmup_result = decoded_rerank(&warmup, "warm-up");
    eprintln!(
        "KANAI_AI_RERANK cold_start status={:?} elapsed_ms={} probe_bound_ms={} \
         shipped_deadline_ms={} covers_cold_start={} \
         note=the probe bound is the protocol cap, so a timeout here means no \
         protocol-legal deadline covers a cold start",
        warmup_result.status,
        cold_elapsed_ms,
        COLD_PROBE_BOUND_MS,
        MEASURED_DEADLINE_MS,
        cold_elapsed_ms <= u128::from(MEASURED_DEADLINE_MS)
    );
    assert_eq!(
        warmup_result.status,
        kanai_broker::EnhancementStatus::Applied,
        "the first real completion must be deliverable within the protocol cap: {:?} after \
         {} ms at a {} ms probe bound. No deadline the protocol permits covers a cold start, \
         so the runtime must warm the model before it reports ready.",
        warmup_result.status,
        cold_elapsed_ms,
        COLD_PROBE_BOUND_MS
    );

    // 2. The distribution, at the shipped deadline.
    let mut latencies: Vec<u128> = Vec::with_capacity(SAMPLES);
    let mut applied = 0_usize;
    let mut changed_positions = 0_u16;
    let mut adopted = 0_usize;
    for _ in 0..SAMPLES {
        let started = Instant::now();
        let response = tokio::time::timeout(
            Duration::from_secs(120),
            coordinator.handle(
                request(MEASURED_DEADLINE_MS),
                token.clone(),
                CancellationToken::new(),
            ),
        )
        .await
        .expect("a measured rerank must not hang");
        latencies.push(started.elapsed().as_millis());
        let result = decoded_rerank(&response, "measured case");
        assert_eq!(
            result.status,
            kanai_broker::EnhancementStatus::Applied,
            "at {MEASURED_DEADLINE_MS} ms the real runtime must be able to answer; a \
             fallback here means the shipped deadline is below what the machine can do"
        );
        if result.adopted {
            adopted += 1;
        }
        changed_positions += result.metrics.changed_positions;
        // The one unrecoverable failure: text the model produced that Mozc never
        // submitted would be put in front of the user.
        let submitted: Vec<u64> = candidates().iter().map(|candidate| candidate.id).collect();
        for candidate in &result.ai {
            assert!(
                submitted.contains(&candidate.id),
                "the model invented candidate id {}, which was never submitted",
                candidate.id
            );
        }
        if result.status == kanai_broker::EnhancementStatus::Applied {
            applied += 1;
        }
    }

    // 3. The old deadline, measured last so its abandoned request cannot delay
    //    anything above.
    let before = Instant::now();
    let before_response = tokio::time::timeout(
        Duration::from_secs(120),
        coordinator.handle(
            request(PREVIOUS_DEADLINE_MS),
            token.clone(),
            CancellationToken::new(),
        ),
    )
    .await
    .expect("the before case must not hang");
    let before_elapsed = before.elapsed();
    let before_result = decoded_rerank(&before_response, "before case");
    // The property is not "which non-applied status the coordinator picks" but
    // "no AI order was adopted". On the implementation host it is `TimedOut`,
    // which is the sharpest form of the defect: the model did the work, and the
    // answer was thrown away.
    assert_ne!(
        before_result.status,
        kanai_broker::EnhancementStatus::Applied,
        "at {PREVIOUS_DEADLINE_MS} ms the real runtime cannot answer in time, so the \
         coordinator must not report an applied AI order. If this now fails, the real \
         runtime got fast enough and the shipped deadline is larger than it needs to be."
    );
    // A discarded result repeats the baseline in `ai` so the client's candidate
    // list is untouched - the right product behaviour, and exactly why the defect
    // is invisible from the outside while costing a full CPU inference per
    // keystroke. So the property is "the order is the baseline and nothing was
    // adopted", not "ai is empty".
    assert_eq!(
        before_result
            .ai
            .iter()
            .map(|candidate| candidate.id)
            .collect::<Vec<_>>(),
        before_result
            .baseline
            .iter()
            .map(|candidate| candidate.id)
            .collect::<Vec<_>>(),
        "a discarded result must hand the Mozc order back unchanged"
    );
    assert!(
        !before_result.adopted,
        "a result that was thrown away cannot have been adopted"
    );

    let mut sorted = latencies.clone();
    sorted.sort_unstable();
    let p50 = percentile(&sorted, 1, 2);
    let p95 = percentile(&sorted, 19, 20);
    let p99 = percentile(&sorted, 99, 100);
    evidence::evidence_performed(
        "the_shipped_deadline_is_one_the_real_runtime_meets",
        &format!(
            "before_deadline_ms={PREVIOUS_DEADLINE_MS} before_status={:?} before_elapsed_ms={} \
             shipped_deadline_ms={MEASURED_DEADLINE_MS} samples={SAMPLES} applied={applied} \
             adopted={adopted} changed_positions={changed_positions} \
             p50_ms={p50} p95_ms={p95} p99_ms={p99} max_ms={} raw_ms={:?}",
            before_result.status,
            before_elapsed.as_millis(),
            sorted.last().copied().unwrap_or(0),
            latencies
        ),
    );
    // The cold-start deadline assertion runs HERE, after the distribution has
    // been measured and printed, not where it used to sit.
    //
    // Measured: with the assertion before the distribution, a cold start that
    // misses the deadline panicked at that line and the run ended. Everything
    // below - p50, p95, p99, applied, adopted, changed_positions - was never
    // measured, because the assertion consumed the measurement. The objective
    // asks for p50 / p95 / p99 against the real payload, and on this machine the
    // cold start is the case that occurs, so the distribution was permanently
    // unmeasurable. A red test that also destroys the evidence it was written
    // to gather is worse than a red test.
    //
    // The assertion itself is unchanged and still fails. Only its position moved.
    assert!(
        cold_elapsed_ms <= u128::from(MEASURED_DEADLINE_MS),
        "the shipped deadline of {MEASURED_DEADLINE_MS} ms does not cover a cold start: the \
         first real completion after startup took {cold_elapsed_ms} ms. Every conversion until \
         the model is warm therefore falls back to the Mozc baseline.\n\n\
         Already tried and measured, do not repeat it: a one-token warm-up during startup \
         (ai_runtime::WARM_UP_DEADLINE) completes in about 0.1 s and leaves the first rerank at \
         1.884 s, no better than the 1.587 s measured without it. The cold cost is the prefill \
         of a realistic reading, not the first inference, so warming with a trivial prompt \
         cannot pay it. What is needed is either a warm-up whose prompt is shaped like a real \
         request, or a first-request budget of its own up to the protocol cap. Do not raise the \
         steady-state deadline: the measured warm p99 is about 1.14 s and 2000 ms is the whole \
         protocol cap."
    );

    assert_eq!(applied, SAMPLES, "every measured rerank must be delivered");
    assert!(
        p99 < u128::from(MEASURED_DEADLINE_MS),
        "the observed p99 ({p99} ms) must sit inside the shipped deadline \
         ({MEASURED_DEADLINE_MS} ms), or the deadline is a preference rather than a \
         measurement. raw_ms={latencies:?}"
    );

    runtime.shutdown().await.expect("a confirmed stop");
}

/// A regular-field session and the token that authorises a rerank against it.
///
/// The broker is returned as well and must be **held for the whole test**. Its
/// `GenerationToken` shares an activity flag with the session, and letting the
/// broker go out of scope deactivates it, which makes every later request stale.
/// That is real behaviour, and it has nothing to do with the deadline being
/// measured. Holding the broker is what keeps the measurement about latency.
///
/// A protected field would be refused by the coordinator before any model is
/// contacted, so `Regular` is the case: the model is allowed to answer.
fn regular_session() -> (Broker<DeterministicBackend>, GenerationToken) {
    let mut broker = Broker::new(DeterministicBackend::new());
    broker.handle(RequestEnvelope::new(
        1,
        RequestCommand::CreateSession(CreateSessionRequest {
            session_id: 9,
            locale: "ja-JP".to_owned(),
            field_class: FieldClass::Regular,
        }),
    ));
    let token = broker.enhancement_token(9).expect("a session token");
    (broker, token)
}

/// A directory junction, so a staged payload under a Japanese repository path can
/// be reached through an ASCII path. A junction is used rather than a symbolic
/// link because it needs no elevation and no developer mode.
struct AsciiJunction {
    #[allow(dead_code)]
    path: PathBuf,
    _target: JunctionGuard,
}

impl AsciiJunction {
    fn create(path: &Path, target: &Path) -> Self {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        // `New-Item -ItemType Junction` rather than `mklink /J`. Both work, but
        // `mklink` is a cmd internal whose diagnostics went to stdout and came
        // back empty here, so a failure arrived as a blank panic message. This is
        // the same call `tests/ai_runtime.rs` uses, and it is proven on this host.
        let script = format!(
            "New-Item -ItemType Junction -Path {} -Target {} -ErrorAction Stop | Out-Null",
            quote_for_powershell(&path.to_string_lossy()),
            quote_for_powershell(&target.to_string_lossy())
        );
        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .expect("PowerShell runs");
        assert!(
            output.status.success(),
            "the ASCII junction at {} -> {} could not be created: stdout={} stderr={}",
            path.display(),
            target.display(),
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        Self {
            path: path.to_path_buf(),
            _target: JunctionGuard(path.to_path_buf()),
        }
    }
}

/// A single-quoted PowerShell string literal, so a path containing a space or a
/// quote cannot become a second argument.
fn quote_for_powershell(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

struct JunctionGuard(PathBuf);

impl Drop for JunctionGuard {
    fn drop(&mut self) {
        // `rmdir` on a junction removes the link, never the target tree.
        let _ = std::process::Command::new("cmd.exe")
            .args(["/d", "/c", "rmdir"])
            .arg(&self.0)
            .output();
    }
}
