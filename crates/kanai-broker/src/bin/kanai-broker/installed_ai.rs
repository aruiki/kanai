//! Installed Windows AI composition. No configuration or readiness work is
//! awaited by the pipe listener, and no lock is held across a model request.
use std::sync::{Arc, RwLock};

use kanai_broker::{
    CancellationToken, CandidateRerankRequest, EnhancementBackend, EnhancementError,
    EnhancementPolicy, ProviderLocality, RerankOutput, SemanticAssistOutput, SemanticAssistRequest,
};

#[derive(Default)]
struct Slot {
    backend: Option<Arc<dyn EnhancementBackend>>,
    closed: bool,
}

#[derive(Clone, Default)]
pub(super) struct SwitchableBackend(Arc<RwLock<Slot>>);

impl SwitchableBackend {
    fn install(&self, backend: Arc<dyn EnhancementBackend>) -> bool {
        let Ok(mut slot) = self.0.write() else {
            return false;
        };
        if slot.closed {
            return false;
        }
        slot.backend = Some(backend);
        true
    }

    fn close(&self) {
        if let Ok(mut slot) = self.0.write() {
            slot.closed = true;
            slot.backend = None;
        }
    }

    fn current(&self) -> Result<Arc<dyn EnhancementBackend>, EnhancementError> {
        self.0
            .read()
            .ok()
            .and_then(|slot| slot.backend.clone())
            .ok_or_else(|| {
                EnhancementError::ProviderUnavailable("local AI runtime is unavailable".to_owned())
            })
    }
}

#[async_trait::async_trait]
impl EnhancementBackend for SwitchableBackend {
    fn provider_id(&self) -> &str {
        "installed-local-ai"
    }
    fn locality(&self) -> ProviderLocality {
        ProviderLocality::Local
    }

    async fn rerank(
        &self,
        request: CandidateRerankRequest,
        cancellation: CancellationToken,
    ) -> Result<RerankOutput, EnhancementError> {
        self.current()?.rerank(request, cancellation).await
    }

    async fn semantic_assist(
        &self,
        request: SemanticAssistRequest,
        cancellation: CancellationToken,
    ) -> Result<SemanticAssistOutput, EnhancementError> {
        self.current()?.semantic_assist(request, cancellation).await
    }
}

pub(super) fn policy(setting: Option<&str>) -> EnhancementPolicy {
    match setting {
        // An unset setting is not consent. `EnhancementPolicy`'s own default is
        // `Disabled` and the Unix broker resolves an unset variable the same
        // way, so with no configuration at all nothing is sent to a model and
        // every conversion stays on the Mozc baseline. `local` is the opt-in,
        // and it has to be typed.
        Some("local" | "local-only") => EnhancementPolicy::LocalQualityOnly,
        // Includes unset, disabled/off, and every unknown or misspelled
        // setting: fail closed.
        _ => EnhancementPolicy::Disabled,
    }
}

fn read_config(path: &std::path::Path) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    let file = std::fs::File::open(path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
    }
    let mut bytes = Vec::new();
    file.take(kanai_broker::MAX_RUNTIME_CONFIG_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > kanai_broker::MAX_RUNTIME_CONFIG_BYTES {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
    }
    Ok(bytes)
}

/// The key-bearing backend, wrapped in a per-request ownership check.
///
/// Readiness proved who owned the endpoint once, at startup. That proof is a
/// statement about a moment, and the port can change hands afterwards: a child
/// that exits and a process that takes its port leaves the broker holding a
/// backend whose next request would hand the bearer token and the user's
/// preedit, context, and candidate text to that process. So every request asks
/// again, on a fresh connection, whether the endpoint is still answered by the
/// child this broker started, and a request that cannot be attributed never
/// leaves the process.
///
/// The check costs one loopback connect and a connection-table lookup, bounded by
/// `OWNERSHIP_VERIFY_TIMEOUT`, on a path that already waits on a model.
#[cfg(windows)]
struct OwnedLocalBackend {
    inner: kanai_broker::LocalOpenAiBackend,
    ownership: kanai_broker::ai_runtime::RuntimeOwnership,
}

#[cfg(windows)]
impl OwnedLocalBackend {
    /// Refuse to forward a request to an endpoint this broker cannot name.
    async fn guard(&self, cancellation: &CancellationToken) -> Result<(), EnhancementError> {
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        if !self.ownership.verify_endpoint().await {
            return Err(EnhancementError::ProviderUnavailable(
                "local AI runtime is unavailable".to_owned(),
            ));
        }
        Ok(())
    }
}

#[cfg(windows)]
#[async_trait::async_trait]
impl EnhancementBackend for OwnedLocalBackend {
    fn provider_id(&self) -> &str {
        self.inner.provider_id()
    }
    fn locality(&self) -> ProviderLocality {
        self.inner.locality()
    }

    async fn rerank(
        &self,
        request: CandidateRerankRequest,
        cancellation: CancellationToken,
    ) -> Result<RerankOutput, EnhancementError> {
        self.guard(&cancellation).await?;
        self.inner.rerank(request, cancellation).await
    }

    async fn semantic_assist(
        &self,
        request: SemanticAssistRequest,
        cancellation: CancellationToken,
    ) -> Result<SemanticAssistOutput, EnhancementError> {
        self.guard(&cancellation).await?;
        self.inner.semantic_assist(request, cancellation).await
    }
}

/// How long the wait between runtime-state checks starts, and how long it grows
/// to while nothing happens.
///
/// A state change is delivered by the supervisor's own notification, so these
/// bounds only pace the re-read of the cancellation flag, which is a flag rather
/// than a channel. Backing off keeps an idle broker at about one wakeup a second
/// instead of the forty a second a fixed short sleep would cost.
#[cfg(windows)]
const RUNTIME_WATCH_FIRST_SLICE: std::time::Duration = std::time::Duration::from_millis(25);
#[cfg(windows)]
const RUNTIME_WATCH_MAX_SLICE: std::time::Duration = std::time::Duration::from_secs(1);

/// Keep the slot honest while the runtime is installed.
///
/// Returns `Err` when the runtime is no longer running, after closing the slot
/// so the next conversion falls back to the Mozc baseline immediately rather
/// than spending a worker on a request against a closed port. Returns `Ok` when
/// the broker asked to stop.
#[cfg(windows)]
async fn watch_installed_runtime(
    backend: &SwitchableBackend,
    ownership: &kanai_broker::ai_runtime::RuntimeOwnership,
    cancellation: &CancellationToken,
) -> Result<(), &'static str> {
    let mut states = ownership.subscribe_states();
    let mut slice = RUNTIME_WATCH_FIRST_SLICE;
    loop {
        if cancellation.is_cancelled() {
            return Ok(());
        }
        if !ownership.is_running() {
            backend.close();
            return Err("local AI runtime stopped");
        }
        tokio::select! {
            // The normal case: the supervisor publishes, and the wait ends.
            changed = states.changed() => {
                if changed.is_err() {
                    backend.close();
                    return Err("local AI runtime stopped");
                }
                slice = RUNTIME_WATCH_FIRST_SLICE;
            }
            () = tokio::time::sleep(slice) => {}
        }
        slice = slice.saturating_mul(2).min(RUNTIME_WATCH_MAX_SLICE);
    }
}

#[cfg(windows)]
pub(super) struct BackgroundAi {
    backend: SwitchableBackend,
    cancellation: CancellationToken,
    task: tokio::task::JoinHandle<()>,
}

#[cfg(windows)]
impl BackgroundAi {
    pub(super) fn start(backend: SwitchableBackend, policy: EnhancementPolicy) -> Self {
        let cancellation = CancellationToken::new();
        let worker_backend = backend.clone();
        let worker_cancel = cancellation.clone();
        let task = tokio::spawn(async move {
            if policy == EnhancementPolicy::Disabled {
                return;
            }
            if let Err(reason) = run(worker_backend, worker_cancel).await {
                // Deliberately static diagnostics: no config, paths, tokens or model text.
                eprintln!("kanai-broker optional AI unavailable: {reason}");
            }
        });
        Self {
            backend,
            cancellation,
            task,
        }
    }

    pub(super) async fn shutdown(mut self) {
        self.backend.close();
        self.cancellation.cancel();
        // Startup and supervisor shutdown are bounded; abort is a final safety
        // net whose Drop releases the key and the supervisor's child owner.
        if tokio::time::timeout(std::time::Duration::from_secs(10), &mut self.task)
            .await
            .is_err()
        {
            self.task.abort();
            let _ = (&mut self.task).await;
        }
    }
}

#[cfg(windows)]
impl Drop for BackgroundAi {
    fn drop(&mut self) {
        self.backend.close();
        self.cancellation.cancel();
        self.task.abort();
    }
}

#[cfg(windows)]
struct KeyDirectory(std::path::PathBuf);

#[cfg(windows)]
impl Drop for KeyDirectory {
    fn drop(&mut self) {
        // Remove only our own empty directories, never recurse and never delete a
        // caller-owned file. Runtime and key ownership are dropped before this
        // guard, so the directories are expected to be empty.
        //
        // A failure used to be discarded, which made two different leftovers
        // indistinguishable from a clean teardown: a directory that could not be
        // removed, and a key file that is still readable by this account. It is
        // reported instead, as a static message plus the error kind, because
        // this path embeds the account name.
        for directory in [self.0.join("runtime"), self.0.clone()] {
            match std::fs::remove_dir(&directory) {
                Ok(()) => {}
                // Nothing to clean up is the normal case for the inner directory.
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => eprintln!(
                    "kanai-broker: local AI key directory cleanup incomplete ({})",
                    error.kind()
                ),
            }
        }
    }
}

/// How many directory entries one broker start will examine while reaping stale
/// key directories. A bound, because the sweep reads a shared temporary
/// directory and must not turn a startup into a scan of it.
#[cfg(windows)]
const KEY_SWEEP_BUDGET: usize = 32;

/// The process id recorded in a `KanaAI-<pid>-<nanos>` directory name.
///
/// `None` for any name this crate did not produce, which is what keeps the sweep
/// from touching an unrelated directory that happens to share the prefix.
#[cfg(windows)]
fn key_directory_owner(name: &str) -> Option<u32> {
    let rest = name.strip_prefix("KanaAI-")?;
    let (owner, nonce) = rest.split_once('-')?;
    if owner.is_empty()
        || nonce.is_empty()
        || !owner.bytes().all(|byte| byte.is_ascii_digit())
        || !nonce.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    owner.parse().ok()
}

/// Whether a process id currently names a live process.
#[cfg(windows)]
fn process_is_alive(process_id: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, WAIT_TIMEOUT};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject,
    };

    // SAFETY: `OpenProcess` only needs the synchronise right, and the handle it
    // returns is checked for null before use. `WaitForSingleObject` with a zero
    // timeout only observes the exit code, and the handle is closed exactly once
    // on the way out.
    let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, process_id) };
    if handle.is_null() {
        // No such process, or one this account may not open. Either way the id
        // cannot be the peer that answered a loopback connect, so treating it as
        // not alive is the direction that can only leave something behind.
        return false;
    }
    let signalled = unsafe { WaitForSingleObject(handle, 0) };
    unsafe { CloseHandle(handle) };
    // `WAIT_OBJECT_0` means the process has exited; `WAIT_TIMEOUT` means it is
    // still running. Any other result is a failed query, which is not evidence
    // of life, so it is reported as not alive.
    signalled == WAIT_TIMEOUT
}

/// Remove one stale key directory, and nothing else.
///
/// Only the exact file this crate creates is removed, and the directories are
/// then removed with a non-recursive `remove_dir`, which fails rather than
/// emptying them. A directory holding anything else is therefore left in place
/// and reported as a failure rather than cleaned up.
///
/// A process id is reused after a reboot, so this is a housekeeping measure, not
/// a security boundary: the worst case is that a directory named like this one
/// and holding a file called `runtime/api-key.txt` is removed.
#[cfg(windows)]
fn reap_key_directory(path: &std::path::Path) -> bool {
    let key_file = path.join(kanai_broker::ai_runtime::RUNTIME_API_KEY_FILE_RELATIVE);
    match std::fs::remove_file(&key_file) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return false,
    }
    for directory in [path.join("runtime"), path.to_path_buf()] {
        match std::fs::remove_dir(&directory) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return false,
        }
    }
    true
}

/// Reap key directories that a previous broker left behind.
///
/// A hard kill - `TerminateProcess` from the TSF host, or the installer stopping
/// the broker - runs neither the key file's `Drop` nor this module's guard, so
/// each such kill leaves a `KanaAI-<pid>-<nanos>` directory holding a key that
/// this account can read. Nothing else ever cleans those up.
///
/// # What this will not touch
///
/// * A directory whose recorded process id is still alive, because that id may
///   be a broker running right now whose key is the one it is using. A recycled
///   id makes this conservative: a leftover is kept until that process ends.
/// * This process's own directory.
/// * Any name that is not exactly `KanaAI-<digits>-<digits>`.
/// * A directory whose contents are anything other than the one file this crate
///   creates; see [`reap_key_directory`].
///
/// `process_is_alive` is a parameter so the decision can be exercised without a
/// real process, and so the production and test paths cannot diverge.
#[cfg(windows)]
fn sweep_stale_key_directories(
    root: &std::path::Path,
    own_process_id: u32,
    process_is_alive: impl Fn(u32) -> bool,
) -> usize {
    let Ok(entries) = std::fs::read_dir(root) else {
        return 0;
    };
    let mut reaped = 0;
    for (examined, entry) in entries.flatten().enumerate() {
        if examined >= KEY_SWEEP_BUDGET {
            break;
        }
        let path = entry.path();
        let Some(owner) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(key_directory_owner)
        else {
            continue;
        };
        if owner == own_process_id || process_is_alive(owner) || !path.is_dir() {
            continue;
        }
        if reap_key_directory(&path) {
            reaped += 1;
        }
    }
    reaped
}

#[cfg(windows)]
async fn run(
    backend: SwitchableBackend,
    cancellation: CancellationToken,
) -> Result<(), &'static str> {
    use kanai_broker::LocalOpenAiBackend;
    use kanai_broker::ai_runtime::{
        SUGGESTED_READINESS_DEADLINE, reserve_loopback_port, start_pinned_ai_runtime,
    };

    let (root, manifest, receipt) = tokio::task::spawn_blocking(|| {
        let exe = std::env::current_exe().map_err(|_| "install location unavailable")?;
        let root = exe
            .parent()
            .ok_or("install location unavailable")?
            .join("ai");
        let manifest = read_config(&root.join("manifest-v1.json"))
            .map_err(|_| "manifest unavailable or oversized")?;
        let receipt = read_config(&root.join("STAGING-RECEIPT.json"))
            .map_err(|_| "receipt unavailable or oversized")?;
        Ok::<_, &'static str>((root, manifest, receipt))
    })
    .await
    .map_err(|_| "configuration worker failed")??;
    if cancellation.is_cancelled() {
        return Ok(());
    }
    // Clear what a hard kill left behind before adding to it. A directory whose
    // process id is still alive is a broker that is running right now, so this
    // never takes a live key away; see `sweep_stale_key_directories`.
    let reaped =
        sweep_stale_key_directories(&std::env::temp_dir(), std::process::id(), process_is_alive);
    if reaped > 0 {
        // Counts only. The paths embed the account name.
        eprintln!("kanai-broker: reaped {reaped} stale local AI key directories");
    }
    // Never write under Program Files. PID plus creation time isolates each
    // broker incarnation. The key writer creates private directories and a
    // CREATE_NEW, owner-only key file; an existing key causes a closed failure.
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "clock unavailable")?
        .as_nanos();
    let key_root = std::env::temp_dir().join(format!("KanaAI-{}-{nonce}", std::process::id()));
    let _key_directory = KeyDirectory(key_root.clone());
    let port = reserve_loopback_port().map_err(|_| "loopback port unavailable")?;
    let runtime = start_pinned_ai_runtime(
        &manifest,
        &receipt,
        &root,
        &key_root,
        port,
        SUGGESTED_READINESS_DEADLINE,
        &cancellation,
    )
    .await
    .map_err(|_| "runtime startup failed")?;
    let local = match LocalOpenAiBackend::new_with_api_key(
        runtime.base_url(),
        runtime.pinned_model_id(),
        runtime.api_key().expose(),
    ) {
        Ok(local) => local,
        Err(_) => {
            let _ = runtime.shutdown().await;
            return Err("backend configuration rejected");
        }
    };
    // The ownership handle carries no key, so it can be held for the life of the
    // slot and used to re-prove the endpoint's owner on every request.
    let Some(ownership) = runtime.ownership() else {
        let _ = runtime.shutdown().await;
        return Err("runtime ownership unavailable");
    };
    let owned = Arc::new(OwnedLocalBackend {
        inner: local,
        ownership: ownership.clone(),
    });
    // Waits for the broker's cancellation, or for the runtime to stop running. A
    // runtime that died must not stay installed: every request would otherwise
    // burn a worker for the whole deadline against a port nobody is serving.
    // The reason is kept rather than returned from here, so the teardown below
    // still runs: a runtime that stopped on its own still has a key file and a
    // child to release.
    let stopped = if !cancellation.is_cancelled() && backend.install(owned) {
        watch_installed_runtime(&backend, &ownership, &cancellation)
            .await
            .err()
    } else {
        None
    };
    backend.close();
    runtime
        .shutdown()
        .await
        .map_err(|_| "runtime shutdown was not confirmed")?;
    match stopped {
        Some(reason) => Err(reason),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FailingBackend;
    #[async_trait::async_trait]
    impl EnhancementBackend for FailingBackend {
        fn provider_id(&self) -> &str {
            "fake"
        }
        fn locality(&self) -> ProviderLocality {
            ProviderLocality::Local
        }
        async fn rerank(
            &self,
            _: CandidateRerankRequest,
            _: CancellationToken,
        ) -> Result<RerankOutput, EnhancementError> {
            Err(EnhancementError::ProviderTimeout)
        }
        async fn semantic_assist(
            &self,
            _: SemanticAssistRequest,
            _: CancellationToken,
        ) -> Result<SemanticAssistOutput, EnhancementError> {
            Err(EnhancementError::ProviderTimeout)
        }
    }

    #[tokio::test]
    async fn available_before_startup_and_failed_model_does_not_block_slot() {
        let slot = SwitchableBackend::default();
        let request = CandidateRerankRequest::new(1, 1, vec![]);
        assert!(matches!(
            slot.rerank(request.clone(), CancellationToken::new()).await,
            Err(EnhancementError::ProviderUnavailable(_))
        ));
        assert!(slot.install(Arc::new(FailingBackend)));
        assert!(matches!(
            slot.rerank(request.clone(), CancellationToken::new()).await,
            Err(EnhancementError::ProviderTimeout)
        ));
        slot.close();
        assert!(
            !slot.install(Arc::new(FailingBackend)),
            "late startup cannot reopen a stopped broker"
        );
        assert!(matches!(
            slot.rerank(request, CancellationToken::new()).await,
            Err(EnhancementError::ProviderUnavailable(_))
        ));
    }

    #[test]
    fn explicit_opt_out_and_unknown_settings_disable_bundle() {
        // The opt-in is a typed value, and everything else fails closed. The
        // unset case is asserted separately in
        // `an_unconfigured_broker_never_sends_anything_to_a_model`, because it
        // is a different claim: it is about the absence of any configuration
        // rather than about a value that was present and wrong.
        assert_eq!(policy(Some("local")), EnhancementPolicy::LocalQualityOnly);
        assert_eq!(
            policy(Some("local-only")),
            EnhancementPolicy::LocalQualityOnly
        );
        for setting in ["off", "disabled", "remote", "", "Local", "local "] {
            assert_eq!(
                policy(Some(setting)),
                EnhancementPolicy::Disabled,
                "{setting} must not enable the local AI path"
            );
        }
    }

    #[test]
    fn an_unconfigured_broker_never_sends_anything_to_a_model() {
        // With nothing configured at all, the intent is the same on every
        // platform: `EnhancementPolicy`'s own default and the Unix broker both
        // resolve an unset setting to `Disabled`. A Windows install that
        // resolved it the other way would send the preedit, the context, and the
        // Mozc candidates to a model on every conversion without anyone having
        // asked for it, so this asserts the equality rather than restating the
        // `match` arm.
        assert_eq!(EnhancementPolicy::default(), EnhancementPolicy::Disabled);
        assert_eq!(policy(None), EnhancementPolicy::default());
        assert_ne!(
            policy(None),
            EnhancementPolicy::LocalQualityOnly,
            "an unset setting must not enable the local AI path"
        );
    }

    #[test]
    fn configuration_reads_are_bounded_and_missing_files_fail_soft() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        assert!(read_config(&path).is_err());
        std::fs::write(&path, b"{}").unwrap();
        assert_eq!(read_config(&path).unwrap(), b"{}");
        std::fs::write(
            &path,
            vec![b' '; kanai_broker::MAX_RUNTIME_CONFIG_BYTES + 1],
        )
        .unwrap();
        assert_eq!(
            read_config(&path).unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
    }

    #[cfg(windows)]
    #[test]
    fn a_key_directory_name_records_exactly_one_process_id() {
        // The sweep matches on this shape, so a name it cannot parse must be
        // rejected: `KanaAI-notapid`, `KanaAI-12`, `KanaAI-12-`, `KanaAI-12-3-x`
        // and a bare prefix are all somebody else's directory as far as the
        // sweep is concerned.
        assert_eq!(
            key_directory_owner("KanaAI-4242-1735689600000000000"),
            Some(4242)
        );
        for name in [
            "KanaAI-",
            "KanaAI-12",
            "KanaAI--1",
            "KanaAI-12-",
            "KanaAI-12-3-4",
            "KanaAI-1a-3",
            "KanaAI-12-3x",
            "Other-12-3",
            "KanaiAI-12-3",
        ] {
            assert_eq!(key_directory_owner(name), None, "{name}");
        }
    }

    #[cfg(windows)]
    #[test]
    fn a_stale_key_directory_is_reaped_and_a_live_or_foreign_one_is_not() {
        use kanai_broker::ai_runtime::RUNTIME_API_KEY_FILE_RELATIVE;

        let root = tempfile::tempdir().expect("a temporary root");

        // What a hard kill leaves: this process's own key layout, with a key
        // nobody will ever remove, under a process id that is gone.
        let stale = root.path().join("KanaAI-4242-1735689600000000000");
        std::fs::create_dir_all(stale.parent().expect("a parent")).unwrap();
        std::fs::create_dir_all(stale.join("runtime")).unwrap();
        let stale_key = stale.join(RUNTIME_API_KEY_FILE_RELATIVE);
        std::fs::write(&stale_key, b"a key a hard kill left behind").unwrap();

        // A broker that is running right now. Its key is in use.
        let live = root.path().join("KanaAI-5150-1735689600000000000");
        std::fs::create_dir_all(live.join("runtime")).unwrap();
        std::fs::write(live.join(RUNTIME_API_KEY_FILE_RELATIVE), b"in use").unwrap();

        // This process's own directory.
        let own = root.path().join("KanaAI-5151-1735689600000000000");
        std::fs::create_dir_all(own.join("runtime")).unwrap();
        std::fs::write(own.join(RUNTIME_API_KEY_FILE_RELATIVE), b"mine").unwrap();

        // A directory with the same name shape but content this crate never
        // creates. It must survive: the sweep removes the one known file and
        // then asks the operating system to remove each directory, which fails
        // on anything else rather than emptying it.
        let foreign = root.path().join("KanaAI-4243-1735689600000000000");
        std::fs::create_dir_all(foreign.join("runtime")).unwrap();
        std::fs::write(foreign.join("runtime").join("someone-elses.txt"), b"keep").unwrap();

        // A name the sweep does not own at all.
        let unrelated = root.path().join("KanaAI-notapid-1");
        std::fs::create_dir_all(&unrelated).unwrap();

        let reaped =
            sweep_stale_key_directories(root.path(), 5151, |process_id| process_id == 5150);
        assert_eq!(reaped, 1, "exactly the stale directory is reaped");
        assert!(!stale.exists(), "the stale key directory is gone");
        assert!(!stale_key.exists(), "the key a hard kill left is gone");
        assert!(live.join(RUNTIME_API_KEY_FILE_RELATIVE).is_file());
        assert!(own.join(RUNTIME_API_KEY_FILE_RELATIVE).is_file());
        assert!(foreign.join("runtime").join("someone-elses.txt").is_file());
        assert!(unrelated.is_dir());
    }

    #[cfg(windows)]
    #[test]
    fn the_process_liveness_check_reports_this_process_as_alive() {
        // The sweep's safety depends on being able to tell a live broker from a
        // dead one, so the production predicate is exercised against a process
        // that certainly exists rather than only through a fake.
        assert!(process_is_alive(std::process::id()));
        // A process that has exited is not reported as alive; an id that names no
        // process at all is likewise not alive, which is the branch the sweep
        // relies on to reap a directory a hard kill left.
        assert!(!process_is_alive(0));
    }

    /// A stand-in for the pinned runtime: a real supervisor, a real
    /// [`PinnedAiRuntime`], and a real key file, over a child that can be told
    /// what it owns and when it exits. Nothing here starts a process.
    #[cfg(windows)]
    mod runtime {
        use std::net::{Ipv4Addr, SocketAddr};
        use std::sync::atomic::{AtomicBool, Ordering};

        use async_trait::async_trait;
        use kanai_broker::ai_runtime::{RUNTIME_API_KEY_FILE_RELATIVE, start_planned_ai_runtime};
        use kanai_broker::local_runtime::{
            RUNTIME_LOOPBACK_HOST, RelativeInstalledPath, RuntimeLaunchPlan, TokenReference,
        };
        use kanai_broker::{
            CancellationToken, RuntimeChild, RuntimeProcess, RuntimeProcessError,
            RuntimeStateSnapshot,
        };
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        use tokio::sync::Notify;

        use super::*;

        /// A child that can be told to stop claiming ownership of a connection,
        /// and to exit.
        pub struct FakeChild {
            owns: AtomicBool,
            exited: AtomicBool,
            exit_signal: Notify,
        }

        impl FakeChild {
            pub fn new(owns: bool) -> Arc<Self> {
                Arc::new(Self {
                    owns: AtomicBool::new(owns),
                    exited: AtomicBool::new(false),
                    exit_signal: Notify::new(),
                })
            }

            /// The child stops being able to prove the endpoint is its own.
            pub fn set_owns(&self, owns: bool) {
                self.owns.store(owns, Ordering::Release);
            }

            /// The child exits, exactly as a crashed model server would.
            pub fn exit(&self) {
                self.exited.store(true, Ordering::Release);
                self.exit_signal.notify_one();
            }
        }

        #[async_trait]
        impl RuntimeChild for FakeChild {
            fn verify_connection(&self, _local: SocketAddr, _peer: SocketAddr) -> bool {
                self.owns.load(Ordering::Acquire)
            }

            async fn wait(&self) -> Result<(), RuntimeProcessError> {
                loop {
                    if self.exited.swap(false, Ordering::AcqRel) {
                        return Ok(());
                    }
                    self.exit_signal.notified().await;
                }
            }

            async fn graceful_stop(&self) -> Result<(), RuntimeProcessError> {
                self.exit();
                Ok(())
            }

            async fn force_stop(&self) -> Result<(), RuntimeProcessError> {
                self.exit();
                Ok(())
            }
        }

        /// Hands out the one child, the way a supervisor restart loop sees it.
        pub struct FakeProcess(Arc<FakeChild>);

        #[async_trait]
        impl RuntimeProcess for FakeProcess {
            async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError> {
                Ok(Arc::clone(&self.0) as Arc<dyn RuntimeChild>)
            }
        }

        /// The reviewed launch shape, pointed at `port`.
        pub fn plan(port: u16) -> RuntimeLaunchPlan {
            RuntimeLaunchPlan {
                model_path: RelativeInstalledPath::new("model/qwen2.5-1.5b-instruct-q4_k_m.gguf")
                    .expect("a relative model path"),
                server_path: RelativeInstalledPath::new("runtime/llama-server.exe")
                    .expect("a relative server path"),
                api_key_file_path: RelativeInstalledPath::new(RUNTIME_API_KEY_FILE_RELATIVE)
                    .expect("a relative key path"),
                api_key_token_reference: TokenReference::new("kanai-test-0000")
                    .expect("an opaque token reference"),
                host: RUNTIME_LOOPBACK_HOST.to_owned(),
                port,
                context_size: 2048,
                parallel: 1,
                device: "none".to_owned(),
                gpu_layers: 0,
                no_ui: true,
            }
        }

        /// A staged install root: the three files the adapter names.
        pub fn staged_root() -> tempfile::TempDir {
            let root = tempfile::tempdir().expect("a temporary install root");
            for relative in [
                "runtime/llama-server.exe",
                "model/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            ] {
                let path = root.path().join(relative);
                std::fs::create_dir_all(path.parent().expect("a subdirectory")).unwrap();
                std::fs::write(&path, b"not executed here").unwrap();
            }
            root
        }

        /// A loopback endpoint that records every request and answers `200` to
        /// `/health`, so the readiness probe and, separately, the request gate can
        /// both be observed on the same socket.
        pub async fn recording_endpoint() -> (SocketAddr, Arc<std::sync::Mutex<Vec<u8>>>) {
            let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
                .await
                .expect("a loopback port");
            let address = listener.local_addr().expect("the endpoint address");
            let recorded = Arc::new(std::sync::Mutex::new(Vec::new()));
            tokio::spawn({
                let recorded = Arc::clone(&recorded);
                async move {
                    while let Ok((mut stream, _)) = listener.accept().await {
                        let mut request = Vec::new();
                        let mut buffer = [0_u8; 512];
                        loop {
                            match stream.read(&mut buffer).await {
                                Ok(0) => break,
                                Ok(read) => {
                                    request.extend_from_slice(&buffer[..read]);
                                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                                        break;
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        recorded
                            .lock()
                            .expect("the recorded request lock")
                            .extend_from_slice(&request);
                        let response =
                            b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        let _ = stream.write_all(response).await;
                        let _ = stream.flush().await;
                    }
                }
            });
            (address, recorded)
        }

        /// Everything the recorded bytes have been asked for so far.
        pub fn requests(recorded: &Arc<std::sync::Mutex<Vec<u8>>>) -> String {
            String::from_utf8_lossy(&recorded.lock().expect("the recorded request lock"))
                .into_owned()
        }

        /// Forget what has been recorded, so a later assertion is about the bytes
        /// that arrive after this point rather than about the whole session.
        pub fn clear(recorded: &Arc<std::sync::Mutex<Vec<u8>>>) {
            recorded.lock().expect("the recorded request lock").clear();
        }

        /// Start a real composition over the fake child and the fake endpoint.
        pub async fn start(
            port: u16,
            child: &Arc<FakeChild>,
        ) -> Result<kanai_broker::ai_runtime::PinnedAiRuntime, String> {
            let root = staged_root();
            start_planned_ai_runtime(
                plan(port),
                root.path(),
                Arc::new(FakeProcess(Arc::clone(child))),
                std::time::Duration::from_secs(5),
                &CancellationToken::new(),
            )
            .await
            .map_err(|error| error.to_string())
        }

        /// A rerank request with one candidate, which is the smallest request the
        /// backend will actually put on the wire.
        pub fn rerank_request() -> CandidateRerankRequest {
            let mut request = CandidateRerankRequest::new(
                1,
                1,
                vec![kanai_broker::Candidate {
                    id: 1,
                    text: "会議".to_owned(),
                    reading: Some("かいぎ".to_owned()),
                    rank: 1,
                }],
            );
            request.context_before = "あしたの".to_owned();
            request.context_after = "を設定します。".to_owned();
            request
        }

        /// Silence the unused-import lint for a type used only in a signature
        /// that a Windows-only test does not always instantiate.
        #[allow(dead_code)]
        pub fn snapshot_type_is_used(_: &RuntimeStateSnapshot) {}
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn a_request_is_never_forwarded_to_an_endpoint_the_broker_cannot_name() {
        use runtime::{FakeChild, recording_endpoint, requests, rerank_request, start};

        let (address, recorded) = recording_endpoint().await;
        let child = FakeChild::new(true);
        let started = start(address.port(), &child)
            .await
            .expect("a ready runtime over the fake child");
        let ownership = started.ownership().expect("an ownership handle");
        let inner = kanai_broker::LocalOpenAiBackend::new_with_api_key(
            format!(
                "http://{}:{}",
                kanai_broker::local_runtime::RUNTIME_LOOPBACK_HOST,
                address.port()
            ),
            "test-model",
            "an-ephemeral-test-key",
        )
        .expect("a loopback backend");
        let owned = OwnedLocalBackend { inner, ownership };

        // The control: while the child can prove it owns the connection, the
        // request is forwarded. Without this the assertions below would also pass
        // against a harness that never sends anything at all.
        let _ = owned
            .rerank(rerank_request(), CancellationToken::new())
            .await;
        assert!(
            requests(&recorded).contains("/v1/chat/completions"),
            "the control request must reach the endpoint, otherwise the next assertion is vacuous"
        );

        // A process that won the port race, or a child that has exited, is not
        // something this broker can name, so the request must not be sent at all:
        // no preedit, no context, no candidate, and no bearer token. Only the
        // bytes recorded from here on are evidence, which is why the control's
        // request is forgotten first.
        child.set_owns(false);
        runtime::clear(&recorded);
        let outcome = owned
            .rerank(rerank_request(), CancellationToken::new())
            .await;
        assert!(
            matches!(outcome, Err(EnhancementError::ProviderUnavailable(_))),
            "an unproven endpoint must not answer a request: {outcome:?}"
        );
        let after = requests(&recorded);
        assert!(
            !after.contains("/v1/chat/completions"),
            "an unproven endpoint must receive no request: {after}"
        );
        assert!(
            !after.to_ascii_lowercase().contains("authorization"),
            "the bearer token must not reach an unproven endpoint: {after}"
        );
        let _ = started.shutdown().await;
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn a_runtime_that_stops_closes_the_slot_instead_of_serving_from_a_dead_port() {
        use runtime::{FakeChild, recording_endpoint, start};
        use std::time::Duration;

        let (address, _recorded) = recording_endpoint().await;
        let child = FakeChild::new(true);
        let started = start(address.port(), &child)
            .await
            .expect("a ready runtime over the fake child");
        let ownership = started.ownership().expect("an ownership handle");
        let slot = SwitchableBackend::default();
        assert!(slot.install(Arc::new(FailingBackend)));

        let cancellation = CancellationToken::new();
        let watcher = tokio::spawn({
            let slot = slot.clone();
            let ownership = ownership.clone();
            let cancellation = cancellation.clone();
            async move { watch_installed_runtime(&slot, &ownership, &cancellation).await }
        });
        // A live runtime and no state change: the watcher waits on the
        // supervisor's own notification rather than returning. The wake-up rate
        // while idle comes from the backoff constants; what this observes is that
        // nothing else ends the wait.
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(
            !watcher.is_finished(),
            "a running runtime must keep the slot"
        );

        // The model server dies. Its port may now belong to anything, and no
        // request may be sent there, and no request may be spent waiting for a
        // port that will never answer.
        child.exit();
        let outcome = tokio::time::timeout(Duration::from_secs(5), watcher)
            .await
            .expect("the watcher must react to a dead runtime")
            .expect("the watcher must not panic");
        assert_eq!(outcome, Err("local AI runtime stopped"));
        assert!(
            matches!(
                slot.rerank(
                    CandidateRerankRequest::new(1, 1, vec![]),
                    CancellationToken::new()
                )
                .await,
                Err(EnhancementError::ProviderUnavailable(_))
            ),
            "a dead runtime must leave the Mozc baseline in charge immediately"
        );
        let _ = started.shutdown().await;
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn the_watch_returns_when_the_broker_asks_to_stop() {
        use runtime::{FakeChild, recording_endpoint, start};

        let (address, _recorded) = recording_endpoint().await;
        let child = FakeChild::new(true);
        let started = start(address.port(), &child)
            .await
            .expect("a ready runtime over the fake child");
        let ownership = started.ownership().expect("an ownership handle");
        let slot = SwitchableBackend::default();
        assert!(slot.install(Arc::new(FailingBackend)));
        let cancellation = CancellationToken::new();
        let watcher = tokio::spawn({
            let slot = slot.clone();
            let ownership = ownership.clone();
            let cancellation = cancellation.clone();
            async move { watch_installed_runtime(&slot, &ownership, &cancellation).await }
        });
        cancellation.cancel();
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), watcher)
            .await
            .expect("cancellation must end the watch")
            .expect("the watcher must not panic");
        assert_eq!(outcome, Ok(()));
        // A cancelled broker is shutting down, so the slot keeps whatever the
        // shutdown path decides; the watcher itself must not report a failure.
        let _ = started.shutdown().await;
    }
}
