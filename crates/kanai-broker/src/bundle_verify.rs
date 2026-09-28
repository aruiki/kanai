//! Startup verification of the pinned local AI bytes on this machine.
//!
//! # Why this module exists
//!
//! User decision D-7 embeds the launch plan in the broker at build time,
//! because the installer deliberately refuses to ship `manifest-v1.json` and
//! `STAGING-RECEIPT.json` and the broker used to require both.  That removed
//! the documents, and with them the only place the launch policy's identity
//! claims lived.  Without something in their place the broker would start the
//! pinned runtime on whatever bytes happen to be on disk while reporting a
//! verified bundle, which is exactly the "verified something that was never
//! checked" failure this repository refuses to ship.
//!
//! So the verification moved to where file access belongs: here, at AI-path
//! startup, against the pinned constants themselves.
//!
//! # What is verified, and what is not
//!
//! Verified, from [`crate::local_runtime::pinned_bundle_layout`]:
//!
//! * the model weight: it exists, its length is exactly
//!   [`PINNED_MODEL_BYTES`](crate::local_runtime::PINNED_MODEL_BYTES), and its
//!   SHA-256 is [`PINNED_MODEL_SHA256`](crate::local_runtime::PINNED_MODEL_SHA256);
//! * the runtime closure: it is a flat directory of regular files, its entry
//!   count is exactly
//!   [`PINNED_RUNTIME_ENTRY_COUNT`](crate::local_runtime::PINNED_RUNTIME_ENTRY_COUNT),
//!   and the digest over its ordinal-sorted names is
//!   [`PINNED_RUNTIME_ENTRY_NAMES_SHA256`](crate::local_runtime::PINNED_RUNTIME_ENTRY_NAMES_SHA256);
//! * the third-party notice: exact length and digest;
//! * both licence texts: present, regular, and non-empty.
//!
//! **Not** verified, stated plainly so that no caller reports more than
//! happened:
//!
//! * **The bytes of the 51 runtime closure entries.** The only record of their
//!   digests is the staging receipt, and the installer refuses to ship it. What
//!   is checked is the closure's *composition* - count plus the exact name-set
//!   digest - so a missing, added, or renamed entry is rejected, while the
//!   content of a correctly named entry is **not** proved by this module.
//!   `PinnedBundleVerification::runtime_entry_count` counts inspected names, and
//!   `hashed_file_count` deliberately does not include them.
//! * **The broker executable's own bytes.** An executable cannot pin its own
//!   digest without a hash fixed point. Its identity is bound by the MSI, which
//!   carries a recorded SHA-256 for `kanai-broker.exe`.
//!
//! # Cost, measured
//!
//! Measured on the implementation host against the staged real bundle
//! (`.local/ai-runtime/staged-real-v5`, model 1,117,320,736 bytes), by
//! `cargo test --release -p kanai-broker --test bundle_verify -- --nocapture
//! --test-threads=1` with `KANAI_AI_STAGING_ROOT` set.  The release profile is the
//! one that ships, so release is the number that matters:
//!
//! | build | runs | seconds | model throughput |
//! |---|---|---|---:|
//! | **release** | 4 | **0.622 / 0.589 / 0.590 / 0.591** | ~1,805 MB/s |
//! | debug | 1 | 22.153 | 48.1 MB/s |
//!
//! The debug figure is recorded here only to say this out loud: **it is not the
//! product cost, and quoting it would overstate the startup by about 35 times.**
//! A debug build of this module is also the reason a shell measurement could not
//! stand in for one - see below.
//!
//! Two further measurements, taken with .NET's `SHA256` from PowerShell, which
//! are *not* this module and are recorded so nobody mistakes them for it:
//!
//! | what | bytes | seconds |
//! |---|---:|---:|
//! | model weight digest, 3 runs | 1,117,320,736 | 1.069 / 1.072 / 1.077 |
//! | runtime closure digests, 3 runs | 47,188,765 | 0.707 cold, then 0.048 / 0.045 |
//! | existence and size only, no hashing | - | 0.002 / 0.003 |
//!
//! All of these ran against a warm page cache. A cold cache is slower, which is
//! why the first closure run above is the 0.707 s outlier; the model was not
//! measured cold, so the cold-start cost of this module is **not** established
//! and is not claimed.
//!
//! That cost is paid once, on the AI slow path's startup, never on a key-input
//! path: the module documentation in `ai_runtime` forbids putting model work on
//! the fast path, and this runs from the same background start. It is measured
//! and recorded here rather than assumed. The alternative - skipping it - was
//! rejected because it would leave a verified-sounding claim unchecked.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use crate::local_runtime::{PinnedBundleLayout, entry_names_sha256, pinned_bundle_layout};

/// Streaming chunk size. One mebibyte keeps peak memory flat regardless of how
/// large the pinned weight is.
const HASH_CHUNK_BYTES: usize = 1024 * 1024;

/// A file the verification refused, and why, with no path in the message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum BundleVerifyError {
    /// A required file or directory was absent, or was not the kind of object
    /// the pinned layout requires.
    #[error("a pinned local AI file is missing or is not a regular file")]
    Missing,
    /// A file's length is not the pinned length, or changed while being read.
    #[error("a pinned local AI file has an unexpected size")]
    SizeMismatch,
    /// A file's digest is not the pinned digest.
    #[error("a pinned local AI file does not match its pinned digest")]
    DigestMismatch,
    /// The runtime closure is not the pinned flat entry set.
    #[error("the installed runtime closure is not the pinned entry set")]
    LayoutMismatch,
    /// A licence text is present but empty.
    #[error("a pinned licence text is empty")]
    LicenseEmpty,
    /// The operating system refused to read a pinned file.
    #[error("a pinned local AI file could not be read")]
    IoUnavailable,
    /// The pinned layout itself is not a plain relative path, which would be a
    /// source defect rather than a condition of the install.
    #[error("the pinned layout is not a plain relative path")]
    LayoutUnsafe,
}

/// What the verification established, and what it cost.
///
/// A caller may record this. It contains counts and digests only: no path, no
/// file name, and no key material.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PinnedBundleVerification {
    /// Digest of the model weight that was hashed.
    pub model_sha256: String,
    /// Size of the model weight that was hashed.
    pub model_bytes: u64,
    /// Number of files whose names were inspected in the runtime closure. Their
    /// bytes were **not** hashed; see the module documentation.
    pub runtime_entry_count: usize,
    /// Digest over the runtime closure's ordinal-sorted names.
    pub runtime_entry_names_sha256: String,
    /// Number of files whose bytes were hashed: the model weight and the
    /// notice. The closure entries are counted, not hashed.
    pub hashed_file_count: usize,
    /// Total bytes hashed.
    pub hashed_bytes: u64,
    /// Wall-clock cost of the verification.
    pub elapsed: Duration,
}

/// Verify the pinned bundle installed under `installed_root`.
///
/// Blocking, bounded, and total work: the file set is fixed by the pinned layout,
/// so the bytes read are bounded by the pinned sizes. It performs no network
/// access, starts no process, and writes nothing.
///
/// On any failure the caller keeps the Mozc baseline: every failure is a typed
/// [`BundleVerifyError`] and none of them names a path.
pub fn verify_pinned_bundle(
    installed_root: &Path,
) -> Result<PinnedBundleVerification, BundleVerifyError> {
    let layout = pinned_bundle_layout();
    for relative in [
        &layout.model_relative,
        &layout.server_relative,
        &layout.runtime_directory,
        &layout.license_directory,
        &layout.notice_relative,
        &layout.model_license_relative,
        &layout.runtime_license_relative,
    ] {
        check_relative(relative)?;
    }
    let started = Instant::now();
    let mut hashed_file_count = 0_usize;
    let mut hashed_bytes = 0_u64;

    // The model weight is the only large object, and it decides every answer the
    // runtime will give.
    let (model_bytes, model_sha256) = hash_file(
        &join(installed_root, &layout.model_relative),
        Some(layout.model_bytes),
    )?;
    hashed_file_count += 1;
    hashed_bytes += model_bytes;
    if model_sha256 != layout.model_sha256 {
        return Err(BundleVerifyError::DigestMismatch);
    }

    // The closure's composition, which is all the pinned policy records without
    // a per-file digest list. The entry bytes are deliberately not hashed.
    let (runtime_entry_count, runtime_entry_names_sha256) =
        verify_runtime_closure(installed_root, &layout)?;

    // The notice is small and pinned, so it is checked the same way as the model.
    let (notice_bytes, notice_sha256) = hash_file(
        &join(installed_root, &layout.notice_relative),
        Some(layout.notice_bytes),
    )?;
    hashed_file_count += 1;
    hashed_bytes += notice_bytes;
    if notice_sha256 != layout.notice_sha256 {
        return Err(BundleVerifyError::DigestMismatch);
    }

    // Licence texts: presence and non-emptiness only. The pinned policy records
    // a digest for the runtime licence and not for the model licence, so no
    // digest is claimed for either here.
    for relative in [
        &layout.model_license_relative,
        &layout.runtime_license_relative,
    ] {
        if regular_file_length(&join(installed_root, relative))? == 0 {
            return Err(BundleVerifyError::LicenseEmpty);
        }
    }

    Ok(PinnedBundleVerification {
        model_sha256,
        model_bytes,
        runtime_entry_count,
        runtime_entry_names_sha256,
        hashed_file_count,
        hashed_bytes,
        elapsed: started.elapsed(),
    })
}

/// Check the runtime closure's shape: flat directory of regular files, exact
/// entry count, exact name-set digest.
fn verify_runtime_closure(
    installed_root: &Path,
    layout: &PinnedBundleLayout,
) -> Result<(usize, String), BundleVerifyError> {
    let entries = std::fs::read_dir(join(installed_root, &layout.runtime_directory))
        .map_err(|_| BundleVerifyError::Missing)?;
    let mut names = Vec::with_capacity(64);
    let mut entry_count = 0_u64;
    for entry in entries {
        let entry = entry.map_err(|_| BundleVerifyError::IoUnavailable)?;
        // A reparse point, a symlink, or a nested directory is not the pinned
        // flat archive layout, whatever it happens to be named.
        if !entry
            .file_type()
            .map_err(|_| BundleVerifyError::IoUnavailable)?
            .is_file()
        {
            return Err(BundleVerifyError::LayoutMismatch);
        }
        names.push(
            entry
                .file_name()
                .to_str()
                .ok_or(BundleVerifyError::LayoutMismatch)?
                .to_owned(),
        );
        entry_count += 1;
    }
    if entry_count != layout.runtime_entry_count {
        return Err(BundleVerifyError::LayoutMismatch);
    }
    let digest = entry_names_sha256(&names).map_err(|_| BundleVerifyError::LayoutMismatch)?;
    if digest != layout.runtime_entry_names_sha256 {
        return Err(BundleVerifyError::LayoutMismatch);
    }
    Ok((names.len(), digest))
}

/// Stream one file through SHA-256, optionally asserting an exact length first.
fn hash_file(path: &Path, expected_bytes: Option<u64>) -> Result<(u64, String), BundleVerifyError> {
    let length = regular_file_length(path)?;
    if let Some(expected) = expected_bytes
        && length != expected
    {
        return Err(BundleVerifyError::SizeMismatch);
    }
    let mut file = std::fs::File::open(path).map_err(|_| BundleVerifyError::IoUnavailable)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; HASH_CHUNK_BYTES];
    let mut read_total = 0_u64;
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| BundleVerifyError::IoUnavailable)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        read_total += read as u64;
    }
    // A file that changed underneath the read is not a file whose digest was
    // computed, so refuse rather than report a digest for unknown bytes.
    if read_total != length {
        return Err(BundleVerifyError::SizeMismatch);
    }
    Ok((length, to_hexadecimal(&hasher.finalize())))
}

/// The length of a regular file, rejecting directories, symlinks, and reparse
/// points.
fn regular_file_length(path: &Path) -> Result<u64, BundleVerifyError> {
    let metadata = std::fs::symlink_metadata(path).map_err(|_| BundleVerifyError::Missing)?;
    if !metadata.file_type().is_file() {
        return Err(BundleVerifyError::Missing);
    }
    Ok(metadata.len())
}

/// Join an already-checked installed-relative path onto the root.
fn join(root: &Path, relative: &str) -> PathBuf {
    let mut path = root.to_path_buf();
    for segment in relative.split('/') {
        path.push(segment);
    }
    path
}

/// Refuse a relative path that is not a plain in-root sequence of segments, so
/// that resolving the pinned layout can never escape the installed AI root.
fn check_relative(relative: &str) -> Result<(), BundleVerifyError> {
    if relative.is_empty()
        || relative.starts_with('/')
        || relative.contains('\\')
        || relative.contains(':')
    {
        return Err(BundleVerifyError::LayoutUnsafe);
    }
    for segment in relative.split('/') {
        if segment.is_empty() || segment == "." || segment == ".." {
            return Err(BundleVerifyError::LayoutUnsafe);
        }
    }
    Ok(())
}

fn to_hexadecimal(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(char::from_digit((byte >> 4) as u32, 16).unwrap_or('0'));
        text.push(char::from_digit((byte & 0x0F) as u32, 16).unwrap_or('0'));
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hexadecimal_is_lowercase_and_fixed_width() {
        assert_eq!(to_hexadecimal(&[0x00, 0x0f, 0xa0, 0xff]), "000fa0ff");
        assert_eq!(to_hexadecimal(&[]), "");
    }

    #[test]
    fn a_missing_root_is_a_typed_refusal_not_a_panic() {
        let error = verify_pinned_bundle(Path::new("Z:/kanai-no-such-install-root"))
            .expect_err("a missing root must be refused");
        assert_eq!(error, BundleVerifyError::Missing);
    }

    #[test]
    fn relative_paths_that_could_escape_the_root_are_refused() {
        for relative in ["", "/abs", "..", "a/../b", "a//b", "C:/x", "a\\b", "."] {
            assert_eq!(
                check_relative(relative),
                Err(BundleVerifyError::LayoutUnsafe),
                "{relative:?} must not resolve"
            );
        }
        assert_eq!(
            check_relative("model/qwen2.5-1.5b-instruct-q4_k_m.gguf"),
            Ok(())
        );
    }

    #[test]
    fn the_verifier_and_the_plan_agree_on_where_the_model_is() {
        // A divergence here would hash one file and start another, so the two
        // derivations are compared rather than assumed equal.
        let layout = pinned_bundle_layout();
        let paths =
            crate::local_runtime::pinned_installed_runtime_paths().expect("pinned paths derive");
        assert_eq!(paths.model_relative.as_str(), layout.model_relative);
        assert_eq!(paths.server_relative.as_str(), layout.server_relative);
        assert_eq!(layout.model_bytes, crate::local_runtime::PINNED_MODEL_BYTES);
        assert_eq!(
            layout.model_sha256,
            crate::local_runtime::PINNED_MODEL_SHA256
        );
        assert_eq!(layout.runtime_entry_count, 51);
    }
}
