//! Shared gate for the tests that need the real pinned runtime.
//! # Why a gate and not `#[ignore]`
//!
//! An `#[ignore]`d test reports "ignored" in the test summary. That reads like a
//! result, and it is not one: for years the two real-runtime tests in this crate
//! were ignored and therefore had never run, while the suite was described as
//! green. Two tests that never execute are not evidence, and a summary line that
//! cannot distinguish them from a pass is worse than no line.
//!
//! So the gate is explicit, and every gated test prints one of exactly two
//! machine-greppable lines:
//!
//! ```text
//! KANAI_AI_EVIDENCE=NOT-PERFORMED test=<name> reason=<why>
//! KANAI_AI_EVIDENCE=PERFORMED test=<name> <measured values>
//! ```
//!
//! A log can be read without guessing which of the two happened, and a run that
//! claims neither is a run whose evidence is missing rather than a run that
//! passed.

// Three test binaries include this module and each uses a different part of it,
// so a helper that one of them does not call is still part of the shared gate.
// The exemption is scoped to this file and carries its reason here, rather than
// silencing dead code anywhere else.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

/// Whether the real-runtime evidence tests should run.
///
/// Set `KANAI_AI_EVIDENCE=1`. The staged payload itself is located by
/// `KANAI_AI_STAGING_ROOT`, or discovered under `.local/ai-runtime`.
pub fn real_runtime_evidence_enabled() -> bool {
    matches!(
        std::env::var("KANAI_AI_EVIDENCE").as_deref(),
        Ok("1") | Ok("true")
    )
}

/// The line a gated test prints when it did not run.
pub fn evidence_not_performed(test: &str, reason: &str) {
    eprintln!("KANAI_AI_EVIDENCE=NOT-PERFORMED test={test} reason={reason}");
}

/// The line a gated test prints when it ran, with its measurements.
pub fn evidence_performed(test: &str, detail: &str) {
    eprintln!("KANAI_AI_EVIDENCE=PERFORMED test={test} {detail}");
}

/// The staged runtime root and its staging receipt.
///
/// `KANAI_AI_STAGING_ROOT` wins when set. Otherwise the newest directory under
/// `.local/ai-runtime` that actually contains `runtime\llama-server.exe` and a
/// `STAGING-RECEIPT.json` is used, so a developer who has already staged the
/// payload does not have to name it. Ordering is by name and the newest wins, so
/// an older stage is never silently preferred.
pub fn staged_runtime_and_receipt() -> (PathBuf, PathBuf) {
    let (root, receipt) = resolve_staged_runtime_and_receipt();
    // An evidence run has to say which bytes it used. A receipt that does not
    // name its stage cannot be checked against one, and two runs that silently
    // picked two different stages would produce two contradictory records.
    eprintln!("KANAI_AI_EVIDENCE=STAGE bytes={root:?} receipt={receipt:?}");
    (root, receipt)
}

fn resolve_staged_runtime_and_receipt() -> (PathBuf, PathBuf) {
    if let Ok(root) = std::env::var("KANAI_AI_STAGING_ROOT")
        && !root.trim().is_empty()
    {
        let root = PathBuf::from(root);
        let receipt = root.join("STAGING-RECEIPT.json");
        assert!(
            root.join("runtime").join("llama-server.exe").is_file(),
            "KANAI_AI_STAGING_ROOT does not hold a staged runtime: {root:?}"
        );
        assert!(
            receipt.is_file(),
            "the staged receipt is missing: {receipt:?}"
        );
        return (root, receipt);
    }
    let newest = newest_staged_ai_payload().expect(
        "KANAI_AI_EVIDENCE=1 was requested but no staged AI payload exists. Run \
         scripts/fetch-stage-pinned-ai-runtime.ps1 -Stage, or set KANAI_AI_STAGING_ROOT.",
    );
    let receipt = newest.join("STAGING-RECEIPT.json");
    (newest, receipt)
}

/// An **installed** AI payload root, named by `KANAI_AI_INSTALL_ROOT`.
///
/// This exists because the staged helper above cannot see an installed product,
/// and that is not an oversight in the helper. `STAGING-RECEIPT.json` is written
/// by the staging script and is deliberately **forbidden from becoming an MSI
/// payload file**, so an installed product does not have one and must not. A
/// harness that requires a receipt therefore cannot measure the product a user
/// actually has; it can only ever measure a staging tree, which is where every
/// "the AI works" claim so far came from.
///
/// So the two are separate functions with separate provenance bases:
///
/// * a staged root is proven by the receipt, which names the manifest digest it
///   was written against;
/// * an installed root is proven by the pinned launch plan in `local_runtime` -
///   the same constants the shipped binary uses to decide what to start - plus
///   the byte verification in `crate::bundle_verify`.
///
/// The basis is printed, so a log says which one produced the evidence. Nothing
/// here falls back: an absent root is an error rather than a quiet switch to the
/// other mode, because a run that measured the staging tree while the report
/// claimed the installed one would be worse than no run.
pub fn installed_payload_root() -> PathBuf {
    let named = std::env::var("KANAI_AI_INSTALL_ROOT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            // The conventional per-machine location of the shipped product. Used
            // only when the variable is absent, and its presence is checked below
            // rather than assumed, so a machine without the product gets a clear
            // error instead of a confusing "no such file" from deeper inside.
            let program_files = std::env::var("ProgramFiles").unwrap_or_default();
            PathBuf::from(program_files).join("KanaAI").join("ai")
        });
    let root = named;
    assert!(
        root.join("runtime").join("llama-server.exe").is_file(),
        "KANAI_AI_INSTALL_ROOT does not hold an installed AI payload: {root:?}. \
         Install the AI-bundled MSI, or set KANAI_AI_INSTALL_ROOT to an <install root>\\ai."
    );
    assert!(
        !root.join("STAGING-RECEIPT.json").is_file(),
        "the install root holds a STAGING-RECEIPT.json, which the installer is \
         forbidden from shipping. Either this is a staging tree and the staged \
         evidence path applies, or an installed product has been contaminated; \
         both mean the installed-payload evidence cannot be claimed from here."
    );
    eprintln!(
        "KANAI_AI_EVIDENCE=INSTALL bytes={root:?} \
         basis=pinned-launch-plan-and-bundle-byte-verification receipt=absent-by-design"
    );
    root
}

/// The payload root a measurement should use, with its provenance basis named.
///
/// A measurement does not care whether the bytes came from a staging tree or an
/// install root, but the *evidence* has to say which, so both branches print
/// their basis line and the caller cannot report a number without also reporting
/// where it was measured.
///
/// `KANAI_AI_INSTALL_ROOT` selects the installed product when it is set and that
/// root holds no staging receipt - the shape an install is required to have. When
/// it is unset, the staged path is used, because that is the only thing left to
/// measure. Setting the variable to a root that *does* hold a receipt is not
/// treated as an install: the basis line says so rather than letting an install
/// claim rest on a staging artifact.
pub fn payload_root_for_measurement() -> PathBuf {
    let install_named = std::env::var("KANAI_AI_INSTALL_ROOT")
        .ok()
        .filter(|value| !value.trim().is_empty());
    if let Some(named) = install_named {
        let root = PathBuf::from(named);
        if !root.join("STAGING-RECEIPT.json").is_file() {
            return installed_payload_root();
        }
        eprintln!(
            "KANAI_AI_EVIDENCE=PROVENANCE basis=staged-receipt root={root:?} \
             reason=KANAI_AI_INSTALL_ROOT names a root that holds a STAGING-RECEIPT.json, \
             so it is a staging tree and not an installed product"
        );
    }
    let (root, _receipt) = staged_runtime_and_receipt();
    root
}

fn newest_staged_ai_payload() -> Option<PathBuf> {
    let parent = repository_root().join(".local/ai-runtime");
    let mut stages: Vec<PathBuf> = std::fs::read_dir(&parent)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .filter(|path| path.join("runtime").join("llama-server.exe").is_file())
        .filter(|path| path.join("STAGING-RECEIPT.json").is_file())
        .collect();
    stages.sort();
    stages.pop()
}

/// The repository root, derived from this crate's manifest directory.
///
/// `canonicalize` is deliberately **not** used. On Windows it returns the
/// extended-length form (`\\?\C:\...`), and a junction created with such a target
/// does not resolve: the evidence run then fails with
/// `ProcessRefused(MissingExecutable)` and no clue why. That is not a guess - it
/// is what this helper produced, and it is why the stage is now printed on every
/// run.
///
/// Two `parent` steps reach the repository root from `<repo>/crates/kanai-broker`;
/// a third would escape the repository and make every stage lookup fail silently.
pub fn repository_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("repository root")
        .to_path_buf()
}
