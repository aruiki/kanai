//! Choosing a root for the per-process API key file that the pinned runtime will
//! accept.
//!
//! # Why this exists
//!
//! The key file is passed to the pinned runtime as `--api-key-file <path>`, and
//! the process adapter refuses a non-ASCII command line outright, because a
//! non-ASCII command line is a *silent* AI failure: the runtime starts, the broker
//! believes the slow path is live, and nothing is ever reranked.
//!
//! The key file cannot live under the install root - `C:\Program Files` is not
//! writable by a non-elevated account - so it goes under the user's temporary
//! directory. For a Japanese account name that directory is
//! `C:\Users\<name>\AppData\Local\Temp`, which is not ASCII, so on such a machine
//! the AI path is off permanently and for a reason that never appears in a log
//! line the user would read.
//!
//! # What this does
//!
//! Windows can name the same directory by its 8.3 short name, and a short name
//! is ASCII. So the candidates are tried in order - short form first, long form
//! second - and the first one that is ASCII *and* that this account can actually
//! create a private directory in wins. When no candidate qualifies, the caller is
//! told so by name, instead of the failure surfacing later as an unexplained
//! refusal to start.
//!
//! Nothing here weakens the key file's own protection: the winning directory is
//! still created private, with an owner-only DACL, by the caller.

use std::io;
use std::path::{Path, PathBuf};

/// A root that cannot be used, and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum KeyRootError {
    /// The root is not representable as text, so its bytes cannot be judged.
    #[error("the key root is not valid Unicode")]
    RootNotUnicode,
    /// No candidate was ASCII, so a non-ASCII command line was the only option.
    #[error("no ASCII key root is available on this machine")]
    NoAsciiRoot,
    /// Every ASCII candidate existed but none could be created in.
    #[error("no ASCII key root could be created in")]
    NotCreatable,
}

/// Whether every character of a path is ASCII.
///
/// The test is on the text, not the bytes: a path the runtime cannot spell is a
/// path it refuses, and the only way to know is to look at what the path says.
#[must_use]
pub fn is_ascii_path(path: &Path) -> bool {
    path.to_str().is_some_and(|text| text.is_ascii())
}

/// The candidate roots for a key file, best first.
///
/// `short` is injected so the ordering can be tested without a Windows volume
/// that has 8.3 names for a Japanese account name, which no test machine is
/// guaranteed to have. Duplicates are removed while keeping the first position,
/// because `GetShortPathName` legitimately returns the long form unchanged when a
/// component already has a short name.
#[must_use]
pub fn ascii_key_root_candidates(
    long_root: &Path,
    short: impl Fn(&Path) -> Option<PathBuf>,
) -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::with_capacity(4);
    let mut push = |path: PathBuf| {
        if is_ascii_path(&path) && !candidates.contains(&path) {
            candidates.push(path);
        }
    };
    if let Some(shortened) = short(long_root) {
        push(shortened);
    }
    push(long_root.to_path_buf());
    candidates
}

/// The first candidate this account can create a private key directory in.
///
/// `create` is injected because "can be created in" is the property that
/// actually matters and the one a path comparison cannot answer: a directory can
/// be ASCII, exist, and still be read-only for this principal. The closure
/// creates the directory and returns the path it created, so the caller can hand
/// that path straight to its cleanup guard.
pub fn resolve_ascii_key_root(
    candidates: &[PathBuf],
    mut create: impl FnMut(&Path) -> Result<PathBuf, io::Error>,
) -> Result<PathBuf, KeyRootError> {
    if candidates.is_empty() {
        return Err(KeyRootError::NoAsciiRoot);
    }
    let mut saw_ascii = false;
    for candidate in candidates {
        if !is_ascii_path(candidate) {
            continue;
        }
        saw_ascii = true;
        if let Ok(created) = create(candidate) {
            return Ok(created);
        }
    }
    if saw_ascii {
        Err(KeyRootError::NotCreatable)
    } else {
        Err(KeyRootError::NoAsciiRoot)
    }
}

/// Ask Windows for a directory's 8.3 short name.
///
/// `None` when Windows declines, which includes the case where 8.3 name
/// generation is disabled for the volume. That is not an error: the caller
/// simply falls back to the long form, and the ASCII check decides.
/// Create this broker incarnation's private key directory under the chosen root,
/// and return it.
///
/// `temp_root` is what `std::env::temp_dir()` reported, and `nonce` isolates one
/// broker incarnation from the next. `create` performs the private creation and
/// returns the directory it created.
///
/// The root is chosen by [`resolve_ascii_key_root`], so a machine whose temporary
/// directory is not ASCII - a Japanese account name, for instance - uses the
/// 8.3 short form of the same directory instead of a path the pinned runtime
/// would refuse.
pub fn key_root_for(
    pid: u32,
    nonce: u128,
    temp_root: &Path,
    short: impl Fn(&Path) -> Option<PathBuf>,
    create: impl FnMut(&Path) -> Result<PathBuf, io::Error>,
) -> Result<PathBuf, KeyRootError> {
    if temp_root.to_str().is_none() {
        return Err(KeyRootError::RootNotUnicode);
    }
    let candidates = ascii_key_root_candidates(temp_root, short);
    let mut create = create;
    resolve_ascii_key_root(&candidates, |candidate| {
        create(&candidate.join(format!("KanaAI-{pid}-{nonce}")))
    })
}

#[cfg(windows)]
#[must_use]
pub fn short_path_name(path: &Path) -> Option<PathBuf> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetShortPathNameW;

    const BUFFER_CHARS: usize = 1024;
    let long: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut buffer = vec![0_u16; BUFFER_CHARS];
    // SAFETY: both pointers are NUL-terminated, live for the call, and the
    // buffer length is passed. The return value is the required length, which is
    // only compared against the buffer that was actually supplied.
    let written =
        unsafe { GetShortPathNameW(long.as_ptr(), buffer.as_mut_ptr(), BUFFER_CHARS as u32) };
    if written == 0 || written as usize > BUFFER_CHARS {
        return None;
    }
    let text: Vec<u16> = buffer.into_iter().take(written as usize).collect();
    let shortened = PathBuf::from(String::from_utf16(&text).ok()?);
    (!shortened.as_os_str().is_empty()).then_some(shortened)
}

#[cfg(not(windows))]
#[must_use]
pub fn short_path_name(_path: &Path) -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A Japanese account's temporary directory, which is the shape that makes
    /// the AI path permanently off.
    fn japanese_temp() -> PathBuf {
        PathBuf::from(r"C:\Users\日本語\AppData\Local\Temp")
    }

    /// What Windows would answer for that directory when 8.3 names exist.
    fn japanese_temp_short() -> PathBuf {
        PathBuf::from(r"C:\Users\AB1234~1\AppData\Local\Temp")
    }

    #[test]
    fn a_non_ascii_root_is_recognised_as_such() {
        assert!(!is_ascii_path(&japanese_temp()));
        assert!(is_ascii_path(Path::new(
            r"C:\Users\aruik\AppData\Local\Temp"
        )));
    }

    #[test]
    fn the_key_directory_is_ascii_for_a_japanese_account() {
        // The defect, as a contract. The pinned runtime refuses a non-ASCII
        // command line, so a key file under a Japanese account's %TEMP% leaves
        // the AI path off permanently. On this machine the account name happens
        // to be ASCII, so the shape is injected instead of relied upon.
        let created = key_root_for(
            4242,
            1_735_689_600_000_000_000,
            &japanese_temp(),
            |path| (path == japanese_temp()).then(japanese_temp_short),
            |candidate| Ok(candidate.join("KanaAI-4242-1735689600000000000")),
        )
        .expect("a key directory is created");
        assert!(
            is_ascii_path(&created),
            "the API key file would be reached through a non-ASCII command line, so the \
             pinned runtime would refuse to start and the AI path would stay off: {created:?}"
        );
        assert!(
            created.starts_with(japanese_temp_short()),
            "the short form of the same directory must be used, not a different location: {created:?}"
        );
    }

    #[test]
    fn the_key_directory_keeps_its_incarnation_name() {
        // The sweep in the broker matches `KanaAI-<digits>-<digits>` exactly, so a
        // resolvable root must not change the leaf name.
        let created = key_root_for(
            7,
            99,
            Path::new(r"C:\Users\aruik\AppData\Local\Temp"),
            |path| Some(path.to_path_buf()),
            |candidate| Ok(candidate.to_path_buf()),
        )
        .expect("a key directory is created");
        assert_eq!(
            created,
            PathBuf::from(r"C:\Users\aruik\AppData\Local\Temp\KanaAI-7-99")
        );
    }

    #[test]
    fn the_short_form_is_offered_first_and_a_long_ascii_root_keeps_its_place() {
        let candidates = ascii_key_root_candidates(&japanese_temp(), |path| {
            (path == japanese_temp()).then(japanese_temp_short)
        });
        assert_eq!(
            candidates,
            vec![japanese_temp_short()],
            "a non-ASCII long form must not be offered at all"
        );

        let ascii = PathBuf::from(r"C:\Users\aruik\AppData\Local\Temp");
        let unchanged =
            ascii_key_root_candidates(&ascii, |path| (path == ascii).then(|| ascii.clone()));
        assert_eq!(
            unchanged,
            vec![ascii.clone()],
            "an unchanged short form must not be listed twice"
        );
    }

    #[test]
    fn a_japanese_account_resolves_to_the_ascii_short_form() {
        let candidates = ascii_key_root_candidates(&japanese_temp(), |path| {
            (path == japanese_temp()).then(japanese_temp_short)
        });
        let created =
            resolve_ascii_key_root(&candidates, |candidate| Ok(candidate.join("KanaAI-1-1")))
                .expect("an ASCII root must be found");
        assert_eq!(created, japanese_temp_short().join("KanaAI-1-1"));
    }

    #[test]
    fn a_candidate_that_cannot_be_created_in_falls_through_to_the_next() {
        let first = PathBuf::from(r"C:\Users\AB1234~1\AppData\Local\Temp");
        let second = PathBuf::from(r"C:\Users\aruik\AppData\Local\Temp");
        let candidates = vec![first.clone(), second.clone()];
        let mut attempts: Vec<PathBuf> = Vec::new();
        let created = resolve_ascii_key_root(&candidates, |candidate| {
            attempts.push(candidate.to_path_buf());
            if candidate == first {
                return Err(io::Error::other("read-only"));
            }
            Ok(candidate.join("KanaAI-2-2"))
        })
        .expect("the creatable candidate wins");
        assert_eq!(attempts, vec![first, second.clone()]);
        assert_eq!(created, second.join("KanaAI-2-2"));
    }

    #[test]
    fn no_ascii_candidate_is_named_rather_than_silently_accepted() {
        let candidates = ascii_key_root_candidates(&japanese_temp(), |_| None);
        assert!(candidates.is_empty());
        let error = resolve_ascii_key_root(&candidates, |candidate| {
            panic!("a non-ASCII candidate must never be created in: {candidate:?}")
        })
        .expect_err("a machine with no ASCII root must say so");
        assert_eq!(error, KeyRootError::NoAsciiRoot);
    }

    #[test]
    fn an_ascii_but_uncreatable_root_is_distinguished_from_no_ascii_root() {
        let candidates = vec![PathBuf::from(r"C:\Users\aruik\AppData\Local\Temp")];
        let error = resolve_ascii_key_root(&candidates, |_| Err(io::Error::other("read-only")))
            .expect_err("an uncreatable root must fail");
        assert_eq!(error, KeyRootError::NotCreatable);
    }
}
