//! The startup byte verification, against a real staged bundle when one is here.
//!
//! The unit tests in `bundle_verify` cover the refusals with synthetic input.
//! This file covers the one thing only a real bundle can answer: that the pinned
//! constants describe the bytes that were actually staged, and what verifying
//! them costs in this implementation rather than in a shell.
//!
//! The measurement is opt-in through `KANAI_AI_EVIDENCE=1` and the staged bundle
//! is located by the shared `tests/evidence` gate, so every real-runtime evidence
//! test uses the same switch and resolves the same stage. An earlier version of
//! this file used its own variable, which meant an evidence pass reported this
//! test as "not performed" while three others reported real results. See
//! `tests/evidence`.

use std::path::Path;
use std::time::Instant;

use kanai_broker::{
    PINNED_MODEL_BYTES, PINNED_MODEL_SHA256, PINNED_RUNTIME_ENTRY_COUNT, verify_pinned_bundle,
};

mod evidence;

#[test]
fn the_real_staged_bundle_verifies_and_its_cost_is_reported() {
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(
            "the_real_staged_bundle_verifies_and_its_cost_is_reported",
            "KANAI_AI_EVIDENCE is not set to 1",
        );
        return;
    }
    // Either basis: a staging tree or an installed product. The startup byte
    // verification runs on exactly these bytes, so measuring it on the installed
    // payload is what makes the reported cost a product number. The helper prints
    // which basis was used.
    let root = evidence::payload_root_for_measurement();
    let root = root.as_path();
    assert!(
        root.is_dir(),
        "the payload root is not a directory: {root:?}"
    );

    let started = Instant::now();
    let verification = verify_pinned_bundle(root).expect("the staged bundle verifies");
    let wall = started.elapsed();

    // The substantive claims: the bytes on this machine are the pinned bytes.
    assert_eq!(verification.model_sha256, PINNED_MODEL_SHA256);
    assert_eq!(verification.model_bytes, PINNED_MODEL_BYTES);
    assert_eq!(
        verification.runtime_entry_count as u64,
        PINNED_RUNTIME_ENTRY_COUNT
    );
    // The notice and the model are the two hashed files; the closure entries are
    // inspected by name, not hashed, and the receipt says so.
    assert_eq!(verification.hashed_file_count, 2);
    assert_eq!(verification.hashed_bytes, PINNED_MODEL_BYTES + 3613);

    evidence::evidence_performed(
        "the_real_staged_bundle_verifies_and_its_cost_is_reported",
        &format!(
            "hashed_files={} hashed_bytes={} runtime_entries={} inner_ms={} wall_ms={} \
             model_throughput_mb_s={}",
            verification.hashed_file_count,
            verification.hashed_bytes,
            verification.runtime_entry_count,
            (verification.elapsed.as_micros() / 1000) as u64,
            wall.as_millis(),
            // Recorded rather than asserted: throughput is a property of the
            // machine and the page cache, not of this code.
            (PINNED_MODEL_BYTES as f64 / 1_048_576.0 / verification.elapsed.as_secs_f64() * 1000.0)
                as u64
        ),
    );
}

#[test]
fn a_tampered_weight_is_refused_rather_than_started() {
    if !evidence::real_runtime_evidence_enabled() {
        evidence::evidence_not_performed(
            "a_tampered_weight_is_refused_rather_than_started",
            "KANAI_AI_EVIDENCE is not set to 1",
        );
        return;
    }
    let (root, _) = evidence::staged_runtime_and_receipt();
    // A copy of the tree with the weight replaced by same-length noise must be
    // refused on the digest, not on the size. The whole tree is copied because the
    // verifier reads the model, the closure, the notice and the licences.
    let Ok(temporary) = tempfile::tempdir() else {
        evidence::evidence_not_performed(
            "a_tampered_weight_is_refused_rather_than_started",
            "no temporary directory available",
        );
        return;
    };
    let staged = root.as_path();
    let fake = temporary.path().join("ai");
    copy_tree(staged, &fake);

    let weight = fake.join("model/qwen2.5-1.5b-instruct-q4_k_m.gguf");
    let original = std::fs::read(&weight).expect("the staged weight is readable");
    let mut tampered = original.clone();
    // Flip a byte deep inside the tensor data, not in the header, so the size
    // check cannot be what rejects it.
    let index = tampered.len() / 2;
    tampered[index] ^= 0xFF;
    std::fs::write(&weight, &tampered).expect("the tampered weight is writable");

    let error = verify_pinned_bundle(&fake).expect_err("a tampered weight must be refused");
    assert_eq!(
        error,
        kanai_broker::BundleVerifyError::DigestMismatch,
        "a same-length tampered weight must be refused on its digest"
    );

    // Restoring the bytes must make it verify again, so the refusal above was
    // about the tamper and not about the copy.
    std::fs::write(&weight, &original).expect("the weight is restorable");
    verify_pinned_bundle(&fake).expect("the restored copy verifies");
    evidence::evidence_performed(
        "a_tampered_weight_is_refused_rather_than_started",
        "refused=BundleVerifyError::DigestMismatch restored=verified",
    );
}

fn copy_tree(from: &Path, to: &Path) {
    for entry in std::fs::read_dir(from).expect("the staged root is readable") {
        let entry = entry.expect("a staged entry is readable");
        let target = to.join(entry.file_name());
        if entry
            .file_type()
            .expect("a staged entry has a type")
            .is_dir()
        {
            std::fs::create_dir_all(&target).expect("a staged directory is creatable");
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).expect("a staged file is copyable");
        }
    }
}
