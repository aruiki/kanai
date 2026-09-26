//! Tests for the optional local AI runtime composition.
//!
//! Nothing here starts `llama-server` and nothing here needs the 1.1 GB pinned
//! weight. The process adapter is replaced by a fake that behaves like a live
//! child, and the readiness endpoint is replaced by a socket that answers
//! whatever status the test needs. The one test that would need the real runtime
//! is `#[ignore]`d at the bottom, with its prerequisites in the reason.
//!
//! These tests are Windows-only because the properties they assert are
//! Windows-specific: the key file's access control list, and the key's absence
//! from the runtime's command line. The port and readiness pieces are portable
//! and are covered here for that reason as well.

#![cfg(windows)]

use std::net::{Ipv4Addr, SocketAddr};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use kanai_broker::EnhancementBackend;
use kanai_broker::ai_runtime::{
    MAX_READINESS_DEADLINE, ProcessRefusal, RUNTIME_API_KEY_FILE_RELATIVE,
    RUNTIME_API_KEY_TEXT_BYTES, RuntimeApiKey, RuntimeApiKeyFile, RuntimeProbeError,
    RuntimeReadiness, RuntimeStartupError, SUGGESTED_READINESS_DEADLINE,
    probe_owned_runtime_readiness, probe_runtime_readiness, reserve_loopback_address,
    reserve_loopback_port, start_planned_ai_runtime, windows_process_for_plan,
};
use kanai_broker::local_runtime::{RUNTIME_LOOPBACK_HOST, RuntimeLaunchPlan};
use kanai_broker::{
    CancellationToken, RelativeInstalledPath, RuntimeChild, RuntimeProcess, RuntimeProcessError,
    RuntimeSupervisorState, TokenReference,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Notify;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A child that stays alive until a stop is requested, like a loaded model.
///
/// `owns_connection` models the operating system's ability to attribute the
/// loopback connection to a process. The real adapter proves it from the TCP
/// connection table; here it is a flag, so both branches are reachable - a child
/// that can name its connections, and one that cannot, which is what a listener
/// that won the port race looks like from the broker's side.
struct FakeChild {
    exited: AtomicBool,
    exit_signal: Notify,
    stops: Arc<Notify>,
    forced_stops: Arc<AtomicUsize>,
    owns_connection: AtomicBool,
    /// The endpoints of the last connection this child was asked about, so a test
    /// can assert the probe really did hand the live socket to the check.
    last_verified: std::sync::Mutex<Option<(SocketAddr, SocketAddr)>>,
}

impl FakeChild {
    fn new(stops: Arc<Notify>, forced_stops: Arc<AtomicUsize>) -> Self {
        Self {
            exited: AtomicBool::new(false),
            exit_signal: Notify::new(),
            stops,
            forced_stops,
            owns_connection: AtomicBool::new(true),
            last_verified: std::sync::Mutex::new(None),
        }
    }

    fn exit(&self) {
        self.exited.store(true, Ordering::Release);
        // There is at most one wait future, and `notify_one` also leaves a permit
        // when the monitor has not started waiting yet, so a test can observe the
        // stop whether it looks before or after the request.
        self.exit_signal.notify_one();
    }

    /// Stop (or resume) being able to prove the endpoint's owner.
    fn set_owns_connection(&self, owns: bool) {
        self.owns_connection.store(owns, Ordering::Release);
    }

    fn last_verified(&self) -> Option<(SocketAddr, SocketAddr)> {
        *self.last_verified.lock().expect("the verification lock")
    }
}

#[async_trait]
impl RuntimeChild for FakeChild {
    fn verify_connection(&self, local: SocketAddr, peer: SocketAddr) -> bool {
        *self.last_verified.lock().expect("the verification lock") = Some((local, peer));
        self.owns_connection.load(Ordering::Acquire)
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
        self.forced_stops.fetch_add(1, Ordering::AcqRel);
        self.stops.notify_one();
        self.exit();
        Ok(())
    }

    async fn force_stop(&self) -> Result<(), RuntimeProcessError> {
        self.forced_stops.fetch_add(1, Ordering::AcqRel);
        self.stops.notify_one();
        self.exit();
        Ok(())
    }
}

/// A process factory that hands out [`FakeChild`] handles.
struct FakeProcess {
    child: Arc<FakeChild>,
    starts: AtomicUsize,
    fail_start: bool,
}

impl FakeProcess {
    fn new(stops: Arc<Notify>, forced_stops: Arc<AtomicUsize>) -> Arc<Self> {
        Arc::new(Self {
            child: Arc::new(FakeChild::new(stops, forced_stops)),
            starts: AtomicUsize::new(0),
            fail_start: false,
        })
    }

    /// A factory that always refuses, so a start failure is reachable.
    fn refusing() -> Arc<Self> {
        Arc::new(Self {
            child: Arc::new(FakeChild::new(
                Arc::new(Notify::new()),
                Arc::new(AtomicUsize::new(0)),
            )),
            starts: AtomicUsize::new(0),
            fail_start: true,
        })
    }

    fn starts(&self) -> usize {
        self.starts.load(Ordering::Acquire)
    }
}

#[async_trait]
impl RuntimeProcess for FakeProcess {
    async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError> {
        self.starts.fetch_add(1, Ordering::AcqRel);
        if self.fail_start {
            return Err(RuntimeProcessError::Unavailable);
        }
        Ok(Arc::clone(&self.child) as Arc<dyn RuntimeChild>)
    }
}

/// A socket that answers every request with one fixed HTTP status line.
///
/// This stands in for `llama-server`'s `/health`; it is the smallest thing that
/// can make the readiness probe's contract observable. The request is recorded
/// so a test can assert what the probe did and did not send.
async fn spawn_status_responder(
    status_line: &'static str,
    recorded: Option<Arc<std::sync::Mutex<Vec<u8>>>>,
) -> SocketAddr {
    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("a loopback port for the fake health endpoint");
    let address = listener.local_addr().expect("the fake endpoint address");
    tokio::spawn(async move {
        let response = format!("{status_line}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
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
            if let Some(recorded) = recorded.as_ref() {
                recorded
                    .lock()
                    .expect("the recorded request lock")
                    .extend_from_slice(&request);
            }
            let _ = stream.write_all(response.as_bytes()).await;
            let _ = stream.flush().await;
        }
    });
    address
}

/// A loopback port with nothing listening on it.
///
/// The socket is bound and released so the port is a real loopback port, which
/// makes "nothing is listening" a statement about this machine rather than about
/// a port number nobody chose.
fn closed_loopback_port() -> u16 {
    reserve_loopback_address()
        .expect("a reserved loopback port")
        .port()
}

/// A peer that accepts the connection and then says nothing at all.
///
/// This is the case the closed-port fixture cannot reach: `connect` succeeds, so
/// the probe is inside its read, and the deadline is the only thing that could
/// end it. It is what a socket that is not the runtime - a listener that won the
/// port race, or a runtime wedged mid-request - looks like to the probe.
async fn spawn_stalled_peer(recorded: Option<Arc<std::sync::Mutex<Vec<u8>>>>) -> SocketAddr {
    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("a loopback port for the stalled peer");
    let address = listener.local_addr().expect("the stalled peer address");
    tokio::spawn(async move {
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
            if let Some(recorded) = recorded.as_ref() {
                recorded
                    .lock()
                    .expect("the recorded request lock")
                    .extend_from_slice(&request);
            }
            // Read, record, and never answer. The socket stays open for the life
            // of the task, so the probe is left waiting on a connection that is
            // established and silent.
            tokio::time::sleep(Duration::from_secs(120)).await;
        }
    });
    address
}

/// The SID of the account this test runs as, resolved independently.
///
/// `whoami` is used on purpose. Re-deriving the SID with the same
/// `OpenProcessToken` call the production DACL is built from would prove only
/// that the two are consistent with each other; asking the operating system what
/// account this is, through a different interface, is the independent fact. It
/// is also what makes a wrong-but-not-well-known SID detectable: granting a
/// different local user full access produces an SDDL that names a SID, has one
/// ACE, and contains none of the forbidden well-known ones.
fn current_account_sid() -> String {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let output = std::process::Command::new("whoami")
        .args(["/user", "/fo", "csv", "/nh"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .expect("whoami runs");
    assert!(
        output.status.success(),
        "whoami must report the current account"
    );
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    // `S-1-5-21-...-<rid>`: the prefix, then digits and separators only. A SID
    // with a well-known name in it, or a translated name with spaces, is not what
    // this is looking for and must not be accepted as one.
    text.split(',')
        .map(|field| field.trim().trim_matches('"'))
        .find_map(|field| {
            let rest = field.strip_prefix("S-1-")?;
            rest.bytes()
                .all(|byte| byte.is_ascii_digit() || byte == b'-')
                .then(|| field.to_owned())
        })
        .unwrap_or_else(|| panic!("whoami reported no user SID: {text}"))
}

/// The SDDL of `path`'s discretionary access control list.
fn dacl_sddl(path: &Path) -> String {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::{
        ConvertSecurityDescriptorToStringSecurityDescriptorW, GetNamedSecurityInfoW, SE_FILE_OBJECT,
    };
    use windows_sys::Win32::Security::{DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR};

    let wide = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<u16>>();
    let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: `wide` is a live NUL-terminated wide string and every
    // out-parameter is live; the descriptor the call writes is released below.
    //
    // The return value is deliberately not asserted to be nonzero: on the machine
    // this test was written on, `GetNamedSecurityInfoW` reports 0 for a file it
    // has in fact described. A call with a deliberately wrong object type reports
    // ERROR_PATH_NOT_FOUND and writes nothing, so the descriptor is the
    // observable, and every assertion is on the descriptor's *contents*: a
    // garbage or absent descriptor fails the conversion rather than passing.
    let _reported = unsafe {
        GetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut descriptor,
        )
    };
    assert!(
        !descriptor.is_null(),
        "the security descriptor of {} must be readable back",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("<unprintable>")
    );

    let mut text: *mut u16 = std::ptr::null_mut();
    let mut length = 0_u32;
    // SAFETY: `descriptor` is the live descriptor the call above wrote, and `text`
    // is a live out-parameter for a Win32-allocated wide string.
    let converted = unsafe {
        ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor,
            1,
            DACL_SECURITY_INFORMATION,
            &mut text,
            &mut length,
        )
    };
    assert_ne!(converted, 0, "the DACL must be expressible as SDDL");
    // SAFETY: `text` is a NUL-terminated wide string that is still allocated.
    let sddl = unsafe {
        let mut count = 0_usize;
        while *text.add(count) != 0 {
            count += 1;
        }
        let units = std::slice::from_raw_parts(text, count);
        String::from_utf16_lossy(units)
    };
    // SAFETY: both pointers came from Win32 allocators owned by this scope, and
    // the SDDL copy above is complete.
    unsafe {
        LocalFree(descriptor.cast());
        LocalFree(text.cast());
    }
    sddl
}

/// The principals named by the access ACEs in `sddl`.
///
/// Only granted access ACEs count: an audit or object ACE would change nothing
/// about who can read a file, and an inherited-marker flag would only change how
/// the string is spelled.
fn access_ace_principals(sddl: &str) -> Vec<String> {
    sddl.split("(A;")
        .skip(1)
        .filter_map(|ace| {
            ace.split(';')
                .next_back()
                .map(|principal| principal.trim_end_matches(')').to_owned())
        })
        .collect()
}

/// Assert that a protected, single-principal DACL names exactly this account.
///
/// The protected flag is the part that excludes other users: without it a file
/// created in a shared directory inherits an access ACE, and on a machine with a
/// Japanese profile the key would be readable by other accounts on the box.
fn assert_owner_only_dacl(path: &Path) {
    let sddl = dacl_sddl(path);
    assert!(
        sddl.starts_with("D:P"),
        "the DACL of {} must be protected so nothing is inherited: {sddl}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("<unprintable>")
    );
    assert_eq!(
        access_ace_principals(&sddl),
        vec![current_account_sid()],
        "the DACL of {} must grant exactly the account running the broker, and nobody else: {sddl}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("<unprintable>")
    );
}

/// The reviewed launch shape pointing into `root`, built without a manifest.
///
/// `RuntimeLaunchPlan`'s fields are public, so a test can construct the reviewed
/// shape directly. The production entry point still has to accept the real
/// manifest, which is what the `#[ignore]`d test covers.
fn synthetic_plan(root: &Path, port: u16) -> RuntimeLaunchPlan {
    let _ = root;
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

/// A temporary install root holding the pinned runtime's relative layout.
///
/// The executable and the weights are placeholders: nothing here starts or loads
/// them. The files only have to exist, because the process adapter refuses to
/// build a command line for a layout that is not there.
fn staged_root() -> tempfile::TempDir {
    let root = tempfile::tempdir().expect("a temporary install root");
    let runtime = root.path().join("runtime");
    let model = root.path().join("model");
    std::fs::create_dir_all(&runtime).expect("the runtime directory");
    std::fs::create_dir_all(&model).expect("the model directory");
    std::fs::write(runtime.join("llama-server.exe"), b"not a real executable")
        .expect("a placeholder executable");
    std::fs::write(
        model.join("qwen2.5-1.5b-instruct-q4_k_m.gguf"),
        b"not real weights",
    )
    .expect("placeholder weights");
    root
}

/// An install root whose every path contains a non-ASCII character.
fn non_ascii_root() -> (tempfile::TempDir, PathBuf) {
    let directory = tempfile::tempdir().expect("a temporary install root");
    let root = directory.path().join("モデル");
    std::fs::create_dir_all(root.join("runtime")).expect("the runtime directory");
    std::fs::create_dir_all(root.join("model")).expect("the model directory");
    std::fs::write(
        root.join("runtime").join("llama-server.exe"),
        b"placeholder",
    )
    .expect("a placeholder executable");
    std::fs::write(
        root.join("model").join("qwen2.5-1.5b-instruct-q4_k_m.gguf"),
        b"placeholder",
    )
    .expect("placeholder weights");
    (directory, root)
}

// ---------------------------------------------------------------------------
// Key material
// ---------------------------------------------------------------------------

#[test]
fn generated_keys_are_random_hex_and_not_a_fixed_string() {
    let mut seen = std::collections::HashSet::new();
    for _ in 0..32 {
        let key = RuntimeApiKey::generate().expect("the system CSPRNG");
        let value = key.expose();
        assert_eq!(value.len(), RUNTIME_API_KEY_TEXT_BYTES);
        assert!(
            value
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
            "a key must be lowercase hex so it cannot be split inside a header: {value}"
        );
        // A constant, a fixed string, or a buffer that was never filled would
        // collide with an earlier draw.
        assert!(seen.insert(value.to_owned()), "a key repeated: {value}");
    }
}

#[test]
fn a_key_is_never_rendered_by_debug() {
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");
    let value = key.expose().to_owned();
    // An empty key would make every containment check below vacuously true, which
    // is how a leak test passes while the key is broken.
    assert_eq!(value.len(), RUNTIME_API_KEY_TEXT_BYTES);

    let debug = format!("{key:?}");
    assert!(!debug.contains(&value), "Debug leaked the key: {debug}");
    assert!(
        debug.contains("redacted"),
        "Debug should say that it is redacted: {debug}"
    );
    // The type deliberately has no `Display` impl, so `{}` does not compile at
    // all. That is the stronger half of the guarantee and it is structural: this
    // file could not be written if `Display` existed.
}

#[test]
fn typed_errors_never_mention_key_material() {
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");
    let value = key.expose();
    assert_eq!(value.len(), RUNTIME_API_KEY_TEXT_BYTES);

    let errors = [
        RuntimeStartupError::PortRejected,
        RuntimeStartupError::LaunchPlanInvalid,
        RuntimeStartupError::KeyFilePathRejected,
        RuntimeStartupError::RandomSourceUnavailable,
        RuntimeStartupError::KeyFileCreateFailed,
        RuntimeStartupError::KeyFileRemoveFailed,
        RuntimeStartupError::ProcessRefused(ProcessRefusal::MissingExecutable),
        RuntimeStartupError::ProcessRefused(ProcessRefusal::MissingModel),
        RuntimeStartupError::ProcessRefused(ProcessRefusal::MissingKeyFile),
        RuntimeStartupError::ProcessRefused(ProcessRefusal::NonAsciiCommandPath),
        RuntimeStartupError::ProcessRefused(ProcessRefusal::ArgumentPlanMismatch),
        RuntimeStartupError::SupervisorConfigInvalid,
        RuntimeStartupError::SupervisorStartFailed,
        RuntimeStartupError::SupervisorStopFailed,
        RuntimeStartupError::ReadinessProbe(RuntimeProbeError::Cancelled),
        RuntimeStartupError::Cancelled,
    ];
    for error in errors {
        let rendered = format!("{error} {error:?}");
        assert!(
            !rendered.contains(value),
            "a typed error leaked the key: {rendered}"
        );
    }
}

#[test]
fn the_key_file_holds_exactly_the_key_and_is_removed_on_drop() {
    let directory = tempfile::tempdir().expect("a temporary directory");
    let path = directory.path().join("api-key.txt");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");

    let file = RuntimeApiKeyFile::create(&path, &key).expect("a protected key file");
    assert!(
        path.is_file(),
        "the key file must exist while the guard is alive"
    );
    let contents = std::fs::read_to_string(&path).expect("the key file contents");
    assert_eq!(contents, key.expose());
    assert!(
        !contents.ends_with('\n'),
        "a trailing newline would make the expected key one no header can carry"
    );

    drop(file);
    assert!(!path.exists(), "the key file must be removed on drop");
}

#[test]
fn removing_the_key_file_explicitly_reports_success() {
    let directory = tempfile::tempdir().expect("a temporary directory");
    let path = directory.path().join("api-key.txt");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");

    let file = RuntimeApiKeyFile::create(&path, &key).expect("a protected key file");
    file.remove().expect("removing the key file");
    assert!(!path.exists());
}

#[test]
fn an_existing_key_file_is_preserved_and_refused() {
    let directory = tempfile::tempdir().expect("a temporary directory");
    let path = directory.path().join("api-key.txt");
    std::fs::write(&path, b"preexisting contents").expect("existing file");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");
    assert_eq!(
        RuntimeApiKeyFile::create(&path, &key).err(),
        Some(RuntimeStartupError::KeyFileCreateFailed)
    );
    assert_eq!(
        std::fs::read(&path).expect("preserved file"),
        b"preexisting contents"
    );
}

#[test]
fn a_non_ascii_key_file_path_is_refused_before_anything_is_written() {
    let directory = tempfile::tempdir().expect("a temporary directory");
    // The pinned build is refused rather than started when its command line is
    // not ASCII, and the key-file path is part of that command line, so writing
    // one would leave a secret no runtime could ever read.
    let path = directory.path().join("api-key-モデル.txt");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");

    assert_eq!(
        RuntimeApiKeyFile::create(&path, &key).err(),
        Some(RuntimeStartupError::KeyFilePathRejected)
    );
    assert!(!path.exists(), "a refused path must not be created");
}

#[test]
fn a_key_file_that_cannot_be_created_is_a_typed_error_and_leaves_nothing() {
    let directory = tempfile::tempdir().expect("a temporary directory");
    // A regular file stands where a directory would have to be, so no ancestor
    // can be created and the write cannot succeed. The failure must be typed
    // rather than a panic, and it must not leave a file behind.
    let blocker = directory.path().join("blocker");
    std::fs::write(&blocker, b"not a directory").expect("the blocking file");
    let path = blocker.join("api-key.txt");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");

    assert_eq!(
        RuntimeApiKeyFile::create(&path, &key).err(),
        Some(RuntimeStartupError::KeyFileCreateFailed)
    );
    assert!(!path.exists());
    assert_eq!(
        std::fs::read(&blocker).expect("the blocking file survives"),
        b"not a directory"
    );
}

#[test]
fn a_missing_key_file_directory_chain_is_created() {
    let directory = tempfile::tempdir().expect("a temporary directory");
    // The per-process key root belongs to the caller and nothing else creates
    // it, so the plan's relative key path has to bring its own directories into
    // existence. Without this, every first start on a fresh machine would fail.
    let path = directory
        .path()
        .join("ai")
        .join("runtime")
        .join("api-key.txt");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");

    let file = RuntimeApiKeyFile::create(&path, &key).expect("the key file is created");
    assert!(path.is_file(), "{}", path.display());
    assert!(directory.path().join("ai").join("runtime").is_dir());
    // The value on disk must be the key, and nothing more.
    assert_eq!(
        std::fs::read(&path).expect("the key file is readable"),
        key.expose().as_bytes()
    );

    // Existence is the weaker half of the claim. The production code creates
    // every missing directory in the chain with the same protected DACL as the
    // key file, and the reason is a window: a directory created the ordinary way
    // inherits the parent's ACEs, so between the moment the key file is written
    // and the moment the file's own protected DACL applies, the key would be
    // readable by anything the directory grants - on a machine with a Japanese
    // profile, every other account on the box. Asserting only `is_dir()` left
    // that window completely unobserved.
    for created in [
        directory.path().join("ai"),
        directory.path().join("ai").join("runtime"),
    ] {
        assert_owner_only_dacl(&created);
    }

    file.remove().expect("the key file is removed");
    assert!(!path.exists());
}

#[test]
fn the_key_file_dacl_grants_only_the_broker_account() {
    use windows_sys::Win32::Security::Authorization::SE_FILE_OBJECT;
    let _ = SE_FILE_OBJECT;

    let directory = tempfile::tempdir().expect("a temporary directory");
    let path = directory.path().join("api-key.txt");
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");
    let _file = RuntimeApiKeyFile::create(&path, &key).expect("a protected key file");

    let sddl = dacl_sddl(&path);

    // `P` is the part that excludes other users. A file created the ordinary way
    // in the same directory inherits its DACL - on the machine this was written
    // on, `D:AI(A;ID;...;;;S-1-5-21-...-1002)(A;ID;FA;;;SY)(A;ID;FA;;;BA)...` - so
    // without a protected DACL the key would be readable by another account on the
    // machine and by every local administrator.
    assert!(
        sddl.starts_with("D:P"),
        "the DACL must be protected so nothing is inherited from the directory: {sddl}"
    );
    assert_eq!(
        sddl.matches("(A;;").count(),
        1,
        "exactly one access ACE is expected: {sddl}"
    );
    // *Which* account is the part that was not checked before: an SDDL that
    // named a different local user, or a service account, has one ACE, no
    // well-known SID, and grants full access to somebody who is not this
    // process. The expected principal is resolved from the operating system
    // rather than from the code under test, so this compares two independent
    // answers instead of the code's answer with itself.
    assert_eq!(
        access_ace_principals(&sddl),
        vec![current_account_sid()],
        "the ACE must name this account and no other principal: {sddl}"
    );
    for other in [
        ";;;WD)",
        ";;;BU)",
        ";;;AU)",
        ";;;S-1-1-0",
        ";;;S-1-5-11",
        ";;;S-1-5-32-545",
    ] {
        assert!(
            !sddl.contains(other),
            "the DACL must not grant any other principal: {sddl}"
        );
    }
}

#[test]
fn the_key_never_reaches_the_runtime_command_line() {
    let root = staged_root();
    let port = reserve_loopback_port().expect("a reserved loopback port");
    let plan = synthetic_plan(root.path(), port);
    let key = RuntimeApiKey::generate().expect("the system CSPRNG");
    let value = key.expose().to_owned();
    let key_path = root.path().join(RUNTIME_API_KEY_FILE_RELATIVE);
    let _key_file = RuntimeApiKeyFile::create(&key_path, &key).expect("a protected key file");

    // The adapter has to produce a command line, or there is nothing to inspect.
    // When the staged root is not ASCII the adapter refuses by design, and this
    // test used to fall back to the plan's own argument list in that case - which
    // is the plan builder's vector, not the adapter's resolution of it, so the
    // assertions below passed without the adapter's `resolve_arguments` having
    // been involved at all. There is no adapter output to assert on in that
    // situation, so the condition is reported instead of papered over.
    let process =
        windows_process_for_plan(&plan, root.path(), root.path()).unwrap_or_else(|error| {
            panic!(
                "this test needs an ASCII staging root so the adapter resolves a command line \
                 (the adapter refused with {error:?}). Set TEMP and TMP to an ASCII path such as \
                 C:\\Temp, or run the suite under an ASCII account name."
            )
        });
    let resolved = process.resolved_arguments().to_vec();
    let command_line = process.redacted_command_line();

    // Element by element, on the adapter's own resolved arguments: the key value
    // is not one of them, and it is not a substring of any of them.
    for argument in &resolved {
        let text = argument.to_string_lossy();
        assert_ne!(text, value, "the key reached the command line");
        assert!(
            !text.contains(&value),
            "the key reached the command line: {text}"
        );
        assert!(
            !text.to_ascii_lowercase().contains("authorization"),
            "the command line must not carry a header: {text}"
        );
    }
    assert!(
        !command_line.contains(&value),
        "the key reached the command line: {command_line}"
    );
    assert!(
        !command_line.contains("Authorization"),
        "the command line must not carry a header: {command_line}"
    );
    for argument in plan.launch_arguments() {
        assert_ne!(argument, value, "the key must not be an argument");
    }
    assert!(
        !command_line.contains(plan.api_key_token_reference.as_str()),
        "the opaque reference must not reach the command line: {command_line}"
    );
    // The key *file path* is supposed to be on the command line; if the flag had
    // been lost the child would have no `--api-key-file` at all, which is the
    // unauthenticated-server outcome every check here exists to prevent. The plan
    // stores that relative path with forward slashes and the adapter resolves it
    // to native separators, so the expected value has to be spelled the way the
    // operating system spells it or the comparison would fail for a reason that
    // has nothing to do with the key.
    assert!(command_line.contains("--api-key-file"));
    assert!(command_line.contains(RUNTIME_LOOPBACK_HOST));
    let key_text = key_path
        .to_string_lossy()
        .replace('/', std::path::MAIN_SEPARATOR_STR);
    assert!(
        resolved
            .iter()
            .any(|argument| argument == std::ffi::OsStr::new(&key_text)),
        "the resolved arguments must carry the key file's path: {command_line}"
    );
}

// ---------------------------------------------------------------------------
// Port selection
// ---------------------------------------------------------------------------

#[test]
fn a_reserved_port_is_nonzero_and_on_loopback_only() {
    let address = reserve_loopback_address().expect("a reserved loopback address");
    assert_ne!(
        address.port(),
        0,
        "port 0 would mean the OS did not assign one"
    );
    assert_eq!(
        address.ip(),
        Ipv4Addr::LOCALHOST,
        "the bind must be loopback, never 0.0.0.0"
    );
    assert!(address.ip().is_loopback());
    assert!(address.is_ipv4());

    let port = reserve_loopback_port().expect("a reserved loopback port");
    assert_ne!(port, 0);
}

// ---------------------------------------------------------------------------
// Readiness probe
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_readiness_probe_reports_ready_when_health_answers_200() {
    let address = spawn_status_responder("HTTP/1.1 200 OK", None).await;
    let outcome = probe_runtime_readiness(
        address.port(),
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(outcome, Ok(RuntimeReadiness::Ready));
}

#[tokio::test]
async fn the_readiness_probe_never_sends_a_token() {
    let recorded = Arc::new(std::sync::Mutex::new(Vec::new()));
    let address = spawn_status_responder("HTTP/1.1 200 OK", Some(Arc::clone(&recorded))).await;

    let outcome = probe_runtime_readiness(
        address.port(),
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(outcome, Ok(RuntimeReadiness::Ready));

    let request = String::from_utf8_lossy(&recorded.lock().expect("the request lock")).into_owned();
    assert!(
        request.starts_with("GET /health "),
        "unexpected request: {request}"
    );
    assert!(
        !request.to_ascii_lowercase().contains("authorization"),
        "the health probe must not carry a token: {request}"
    );
}

#[tokio::test]
async fn the_readiness_probe_does_not_accept_a_non_200_status() {
    // A runtime that is listening but not serving is a different state from a
    // closed port, and the probe keeps the two apart.
    let address = spawn_status_responder("HTTP/1.1 503 Service Unavailable", None).await;
    let outcome = probe_runtime_readiness(
        address.port(),
        Duration::from_millis(300),
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(
        outcome,
        Err(RuntimeProbeError::DeadlineElapsed {
            last: RuntimeReadiness::NotServing
        })
    );
}

#[tokio::test]
async fn the_readiness_probe_gives_up_at_its_deadline_instead_of_hanging() {
    let port = closed_loopback_port();
    let deadline = Duration::from_millis(400);
    let started = Instant::now();
    let outcome = probe_runtime_readiness(port, deadline, &CancellationToken::new()).await;
    let elapsed = started.elapsed();

    assert_eq!(
        outcome,
        Err(RuntimeProbeError::DeadlineElapsed {
            last: RuntimeReadiness::NotListening
        })
    );
    assert!(
        elapsed >= deadline,
        "the probe must use its whole deadline, not give up early: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_secs(5),
        "the probe must be bounded by its deadline, not hang: {elapsed:?}"
    );
}

#[tokio::test]
async fn the_readiness_probe_is_cancellable_while_waiting() {
    let port = closed_loopback_port();
    let cancellation = CancellationToken::new();
    let probe = tokio::spawn({
        let cancellation = cancellation.clone();
        async move {
            probe_runtime_readiness(
                port,
                // A deadline far past the cancellation, so a pass can only be
                // explained by the cancellation being observed.
                Duration::from_secs(30),
                &cancellation,
            )
            .await
        }
    });
    tokio::time::sleep(Duration::from_millis(60)).await;
    let started = Instant::now();
    cancellation.cancel();

    let outcome = tokio::time::timeout(Duration::from_secs(5), probe)
        .await
        .expect("a cancelled probe must not hang")
        .expect("the probe task must not panic");
    assert_eq!(outcome, Err(RuntimeProbeError::Cancelled));
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "cancellation must be observed long before the deadline"
    );
}

#[tokio::test]
async fn a_cancelled_token_stops_the_probe_before_any_request() {
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let outcome = probe_runtime_readiness(
        closed_loopback_port(),
        SUGGESTED_READINESS_DEADLINE,
        &cancellation,
    )
    .await;
    assert_eq!(outcome, Err(RuntimeProbeError::Cancelled));
}

#[tokio::test]
async fn the_readiness_probe_is_cancellable_while_a_stalled_peer_holds_the_connection() {
    // The closed-port fixture cannot observe the connected phase: `connect` fails
    // immediately there, so the 25 ms cancellation slicing in the wait between
    // attempts is all that is ever exercised. This peer accepts the connection
    // and then never answers, so the probe is parked inside its read with the
    // whole readiness deadline still ahead of it - which is what a socket that is
    // not the runtime looks like.
    let recorded = Arc::new(std::sync::Mutex::new(Vec::new()));
    let address = spawn_stalled_peer(Some(Arc::clone(&recorded))).await;
    let cancellation = CancellationToken::new();
    let probe = tokio::spawn({
        let cancellation = cancellation.clone();
        async move {
            probe_runtime_readiness(
                address.port(),
                // A deadline far past the cancellation, so a pass can only be
                // explained by the cancellation being observed.
                Duration::from_secs(30),
                &cancellation,
            )
            .await
        }
    });
    // Long enough for the connection to be accepted and the request written.
    tokio::time::sleep(Duration::from_millis(120)).await;
    let started = Instant::now();
    cancellation.cancel();

    let outcome = tokio::time::timeout(Duration::from_secs(5), probe)
        .await
        .expect("a stalled peer must not hold the probe past the cancellation slice")
        .expect("the probe task must not panic");
    assert_eq!(outcome, Err(RuntimeProbeError::Cancelled));
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "cancellation must be observed long before the deadline: {:?}",
        started.elapsed()
    );
    // The peer really did accept the connection and receive the request, so the
    // probe was connected and reading when the cancellation arrived. Without
    // this the assertions above would also pass if the cancellation had simply
    // been seen before the first attempt.
    let request = {
        let recorded = recorded.lock().expect("the recorded request lock");
        String::from_utf8_lossy(&recorded).into_owned()
    };
    assert!(
        request.starts_with("GET /health "),
        "the stalled peer must have received the request: {request}"
    );
}

#[tokio::test]
async fn the_readiness_probe_rejects_an_unusable_port_or_deadline() {
    let token = CancellationToken::new();
    assert_eq!(
        probe_runtime_readiness(0, Duration::from_secs(1), &token).await,
        Err(RuntimeProbeError::InvalidPort)
    );
    assert_eq!(
        probe_runtime_readiness(8080, Duration::ZERO, &token).await,
        Err(RuntimeProbeError::InvalidDeadline)
    );
    assert_eq!(
        probe_runtime_readiness(
            8080,
            MAX_READINESS_DEADLINE + Duration::from_secs(1),
            &token
        )
        .await,
        Err(RuntimeProbeError::InvalidDeadline)
    );
    // The suggestion has to be a value a caller could actually pass, or the
    // measurement behind it would be unusable.
    assert!(SUGGESTED_READINESS_DEADLINE <= MAX_READINESS_DEADLINE);
    assert!(SUGGESTED_READINESS_DEADLINE > Duration::from_millis(1100));
}

// ---------------------------------------------------------------------------
// The composition chain, with a fake process and a fake health endpoint
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_composition_chain_starts_a_ready_runtime_and_owns_its_key() {
    let root = staged_root();
    let address = spawn_status_responder("HTTP/1.1 200 OK", None).await;
    let plan = synthetic_plan(root.path(), address.port());
    let stops = Arc::new(Notify::new());
    let forced = Arc::new(AtomicUsize::new(0));
    let process = FakeProcess::new(Arc::clone(&stops), Arc::clone(&forced));

    let runtime = start_planned_ai_runtime(
        plan,
        root.path(),
        Arc::clone(&process) as Arc<dyn RuntimeProcess>,
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await
    .expect("a ready runtime");

    assert_eq!(process.starts(), 1, "exactly one child must be attached");
    assert_eq!(runtime.port(), address.port());
    assert_eq!(
        runtime.base_url(),
        format!("http://{RUNTIME_LOOPBACK_HOST}:{}", address.port())
    );
    assert_eq!(runtime.snapshot().state, RuntimeSupervisorState::Running);
    assert!(!runtime.pinned_model_id().is_empty());

    let key_path = runtime
        .api_key_file()
        .expect("a live key file")
        .to_path_buf();
    assert!(
        key_path.is_file(),
        "the key file must exist while the runtime is live"
    );
    assert_eq!(
        std::fs::read_to_string(&key_path).expect("the key file contents"),
        runtime.api_key().expose()
    );
    assert!(runtime.api_key().expose().len() >= 32);

    let debug = format!("{runtime:?}");
    assert!(
        !debug.contains(runtime.api_key().expose()),
        "Debug leaked the key: {debug}"
    );
    assert!(
        debug.contains("redacted"),
        "Debug should say that it is redacted: {debug}"
    );

    runtime.shutdown().await.expect("a confirmed stop");
    assert!(!key_path.exists(), "shutdown must remove the key file");
    tokio::time::timeout(Duration::from_secs(5), stops.notified())
        .await
        .expect("the child must be stopped");
    assert!(forced.load(Ordering::Acquire) >= 1);
}

#[tokio::test]
async fn dropping_the_handle_removes_the_key_file_and_stops_the_runtime() {
    let root = staged_root();
    let address = spawn_status_responder("HTTP/1.1 200 OK", None).await;
    let plan = synthetic_plan(root.path(), address.port());
    let stops = Arc::new(Notify::new());
    let forced = Arc::new(AtomicUsize::new(0));
    let process = FakeProcess::new(Arc::clone(&stops), Arc::clone(&forced));

    let runtime = start_planned_ai_runtime(
        plan,
        root.path(),
        Arc::clone(&process) as Arc<dyn RuntimeProcess>,
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await
    .expect("a ready runtime");
    let key_path = runtime
        .api_key_file()
        .expect("a live key file")
        .to_path_buf();
    assert!(key_path.is_file());

    // This is the invariant that matters: a dropped handle must not leave a
    // secret on disk or a model process running.
    drop(runtime);
    assert!(
        !key_path.exists(),
        "dropping the handle must remove the key file"
    );
    tokio::time::timeout(Duration::from_secs(5), stops.notified())
        .await
        .expect("dropping the handle must stop the child");
    assert!(forced.load(Ordering::Acquire) >= 1);
}

#[tokio::test]
async fn a_dropped_handle_leaves_no_replacement_starting_against_a_deleted_key() {
    let root = staged_root();
    let address = spawn_status_responder("HTTP/1.1 200 OK", None).await;
    let plan = synthetic_plan(root.path(), address.port());
    let process = FakeProcess::new(Arc::new(Notify::new()), Arc::new(AtomicUsize::new(0)));
    let runtime = start_planned_ai_runtime(
        plan,
        root.path(),
        Arc::clone(&process) as Arc<dyn RuntimeProcess>,
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await
    .expect("a ready runtime");
    let key_path = runtime
        .api_key_file()
        .expect("a live key file")
        .to_path_buf();

    // The child is on its way out with a restart pending. This is the state the
    // release order exists for: the supervisor can be holding a backoff towards
    // a replacement at the moment the handle goes away, and the replacement is
    // what would have been pointed at a key file that is about to be deleted.
    // The child is already gone here, so no stop request is expected afterwards.
    process.child.exit();
    drop(runtime);
    assert!(
        !key_path.exists(),
        "the key file must be gone once the handle is dropped"
    );

    // No replacement may be started after the handle is gone: that is the whole
    // content of "a missing key file must not become a loopback model server
    // without authentication". The supervisor is released before the removal, so
    // its closed flag forbids the pending restart; the adapter re-checks the key
    // file on every start as the second, independent barrier, which the adapter's
    // own tests cover with a real executable.
    //
    // What this cannot observe is the interleaving *inside* `Drop`, which is two
    // adjacent statements: a test cannot deterministically catch a race that
    // narrow, and a test that claims to would be asserting luck. The invariant
    // the reordering establishes - a released supervisor starts nothing - is what
    // is asserted here, and it is what the second barrier covers the rest.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        process.starts(),
        1,
        "no replacement may be started after the handle is dropped"
    );
}

/// A `200` from a peer this broker cannot name is not readiness.
///
/// The port is served, the status line is a valid `200`, and the start still
/// fails: the only thing that distinguishes the pinned runtime from a process
/// that won the port race between `reserve_loopback_port`'s release and the
/// runtime's own `bind` is which process the operating system says owns the
/// connection, and that has to be proven before anything is sent.
#[tokio::test]
async fn a_peer_the_broker_cannot_name_is_never_declared_ready() {
    let root = staged_root();
    let address = spawn_status_responder("HTTP/1.1 200 OK", None).await;
    let plan = synthetic_plan(root.path(), address.port());
    let stops = Arc::new(Notify::new());
    let process = FakeProcess::new(Arc::clone(&stops), Arc::new(AtomicUsize::new(0)));
    process.child.set_owns_connection(false);
    let expected = root.path().join(RUNTIME_API_KEY_FILE_RELATIVE);

    let outcome = start_planned_ai_runtime(
        plan,
        root.path(),
        Arc::clone(&process) as Arc<dyn RuntimeProcess>,
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await;

    assert_eq!(
        outcome.err(),
        Some(RuntimeStartupError::ReadinessProbe(
            RuntimeProbeError::PeerOwnershipUnproven
        ))
    );
    // The proof was asked about the socket the request actually went out on, not
    // about some other connection to the same port: the peer end is the endpoint
    // and the local end is a different, ephemeral port.
    let (local, peer) = process
        .child
        .last_verified()
        .expect("the probe must put the live socket to the ownership check");
    assert_eq!(peer.port(), address.port(), "the peer end is the endpoint");
    assert!(local.ip().is_loopback() && local.port() != 0);
    assert_ne!(
        local.port(),
        address.port(),
        "the check must be about this connection, not the listener's port"
    );
    assert!(
        !expected.exists(),
        "a refused start must not leave key material behind"
    );
    tokio::time::timeout(Duration::from_secs(5), stops.notified())
        .await
        .expect("a refused start must not leave a runtime behind either");
    assert_eq!(
        process.starts(),
        1,
        "an unowned peer is refused once, not probed again"
    );
}

#[tokio::test]
async fn the_owned_readiness_probe_refuses_a_peer_whose_owner_cannot_be_proved() {
    let root = staged_root();
    let address = spawn_status_responder("HTTP/1.1 200 OK", None).await;
    let plan = synthetic_plan(root.path(), address.port());
    let process = FakeProcess::new(Arc::new(Notify::new()), Arc::new(AtomicUsize::new(0)));
    let runtime = start_planned_ai_runtime(
        plan,
        root.path(),
        Arc::clone(&process) as Arc<dyn RuntimeProcess>,
        Duration::from_secs(5),
        &CancellationToken::new(),
    )
    .await
    .expect("a ready runtime");
    let ownership = runtime.ownership().expect("an ownership handle");

    // The positive case first, so the negative one cannot pass merely because
    // the endpoint was unreachable.
    assert_eq!(
        probe_owned_runtime_readiness(
            address.port(),
            Duration::from_secs(2),
            &CancellationToken::new(),
            &ownership
        )
        .await,
        Ok(RuntimeReadiness::Ready)
    );

    // The child can no longer be named as the owner. This is refused at once
    // rather than retried until the deadline: an unowned peer must not get a
    // second request just because the first attempt could not attribute it.
    process.child.set_owns_connection(false);
    let started = Instant::now();
    assert_eq!(
        probe_owned_runtime_readiness(
            address.port(),
            Duration::from_secs(30),
            &CancellationToken::new(),
            &ownership
        )
        .await,
        Err(RuntimeProbeError::PeerOwnershipUnproven)
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "an unowned peer must be refused immediately, not at the deadline: {:?}",
        started.elapsed()
    );
    let _ = runtime.shutdown().await;
}

#[tokio::test]
async fn a_process_that_cannot_start_is_a_typed_error_and_removes_the_key_file() {
    let root = staged_root();
    let plan = synthetic_plan(root.path(), closed_loopback_port());
    let expected = root.path().join(RUNTIME_API_KEY_FILE_RELATIVE);

    let outcome = start_planned_ai_runtime(
        plan,
        root.path(),
        FakeProcess::refusing(),
        Duration::from_millis(200),
        &CancellationToken::new(),
    )
    .await;

    assert_eq!(
        outcome.err(),
        Some(RuntimeStartupError::SupervisorStartFailed)
    );
    assert!(
        !expected.exists(),
        "a failed start must not leave key material behind"
    );
}

#[tokio::test]
async fn a_runtime_that_never_becomes_ready_is_a_typed_error_and_cleans_up() {
    let root = staged_root();
    // Nothing is listening on this port, so the probe reaches its deadline.
    let plan = synthetic_plan(root.path(), closed_loopback_port());
    let expected = root.path().join(RUNTIME_API_KEY_FILE_RELATIVE);
    let stops = Arc::new(Notify::new());

    let outcome = start_planned_ai_runtime(
        plan,
        root.path(),
        FakeProcess::new(Arc::clone(&stops), Arc::new(AtomicUsize::new(0))),
        Duration::from_millis(300),
        &CancellationToken::new(),
    )
    .await;

    assert_eq!(
        outcome.err(),
        Some(RuntimeStartupError::ReadinessProbe(
            RuntimeProbeError::DeadlineElapsed {
                last: RuntimeReadiness::NotListening
            }
        ))
    );
    assert!(
        !expected.exists(),
        "an unready runtime must not leave key material behind"
    );
    tokio::time::timeout(Duration::from_secs(5), stops.notified())
        .await
        .expect("an unready runtime must be stopped on the way out");
}

#[tokio::test]
async fn a_cancelled_start_is_refused_before_anything_is_created() {
    let root = staged_root();
    let plan = synthetic_plan(root.path(), closed_loopback_port());
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let expected = root.path().join(RUNTIME_API_KEY_FILE_RELATIVE);

    let outcome = start_planned_ai_runtime(
        plan,
        root.path(),
        FakeProcess::new(Arc::new(Notify::new()), Arc::new(AtomicUsize::new(0))),
        Duration::from_secs(1),
        &cancellation,
    )
    .await;

    assert_eq!(outcome.err(), Some(RuntimeStartupError::Cancelled));
    assert!(!expected.exists());
}

#[tokio::test]
async fn an_unusable_deadline_is_refused_before_a_process_or_a_key_file() {
    let root = staged_root();
    let plan = synthetic_plan(root.path(), closed_loopback_port());
    let expected = root.path().join(RUNTIME_API_KEY_FILE_RELATIVE);
    let process = FakeProcess::new(Arc::new(Notify::new()), Arc::new(AtomicUsize::new(0)));

    let outcome = start_planned_ai_runtime(
        plan,
        root.path(),
        Arc::clone(&process) as Arc<dyn RuntimeProcess>,
        Duration::ZERO,
        &CancellationToken::new(),
    )
    .await;

    assert_eq!(
        outcome.err(),
        Some(RuntimeStartupError::ReadinessProbe(
            RuntimeProbeError::InvalidDeadline
        ))
    );
    assert_eq!(process.starts(), 0, "no child may be started");
    assert!(!expected.exists(), "no key material may be created");
}

#[tokio::test]
async fn a_non_ascii_install_root_is_refused_before_key_material_exists() {
    let (_directory, root) = non_ascii_root();
    let plan = synthetic_plan(&root, closed_loopback_port());
    let expected = root.join(RUNTIME_API_KEY_FILE_RELATIVE);

    // The key-file path is part of the command line and the pinned build is
    // refused when that is not ASCII, so no key is written for a root that could
    // never start a runtime.
    let outcome = start_planned_ai_runtime(
        plan,
        &root,
        FakeProcess::new(Arc::new(Notify::new()), Arc::new(AtomicUsize::new(0))),
        Duration::from_secs(1),
        &CancellationToken::new(),
    )
    .await;

    assert_eq!(
        outcome.err(),
        Some(RuntimeStartupError::KeyFilePathRejected)
    );
    assert!(!expected.exists());
}

#[test]
fn a_missing_executable_is_a_typed_refusal_and_nothing_is_started() {
    let directory = tempfile::tempdir().expect("a temporary install root");
    let plan = synthetic_plan(directory.path(), closed_loopback_port());
    assert_eq!(
        windows_process_for_plan(&plan, directory.path(), directory.path()).err(),
        Some(ProcessRefusal::MissingExecutable)
    );
}

#[test]
fn a_missing_key_file_is_a_typed_refusal() {
    let root = staged_root();
    let plan = synthetic_plan(root.path(), closed_loopback_port());
    // The key file is deliberately absent, which is the state a caller is in if it
    // builds the process adapter before this module writes the key.
    assert_eq!(
        windows_process_for_plan(&plan, root.path(), root.path()).err(),
        Some(ProcessRefusal::MissingKeyFile)
    );
}

// ---------------------------------------------------------------------------
// The one test that needs the real pinned runtime
// ---------------------------------------------------------------------------

/// Requires a staged pinned runtime: the 1.1 GB weight, `llama-server.exe`, and
/// the staging receipt that `scripts/stage-tsf-runtime.ps1` writes. Point
/// `KANAI_AI_STAGED_ROOT` at the staged directory and `KANAI_AI_STAGING_RECEIPT`
/// at its `STAGING-RECEIPT.json`; the pinned manifest is read from the
/// repository. Ignored by default because it starts a real process and loads the
/// model, so it cannot be part of the ordinary suite.
#[tokio::test]
#[ignore = "needs a staged 1.1 GB model, a real llama-server.exe, and a staging receipt"]
async fn the_pinned_runtime_becomes_ready_against_a_staged_install() {
    let root = PathBuf::from(
        std::env::var("KANAI_AI_STAGED_ROOT")
            .expect("KANAI_AI_STAGED_ROOT must point at the staged runtime root"),
    );
    let receipt = PathBuf::from(
        std::env::var("KANAI_AI_STAGING_RECEIPT")
            .expect("KANAI_AI_STAGING_RECEIPT must point at the staged STAGING-RECEIPT.json"),
    );
    let manifest_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../platform/windows-tsf/ai-runtime/manifest-v1.json");
    let manifest_json = std::fs::read(&manifest_path).expect("the pinned manifest");
    let receipt_json = std::fs::read(&receipt).expect("the staging receipt");

    // This repository lives under a Japanese path, and the pinned runtime is
    // refused rather than started when its command line is not ASCII. The staged
    // bytes are therefore reached through an ASCII directory junction, and the
    // key file is written to a separate ASCII writable root, which is also how a
    // real install behaves: the payload lives under Program Files and the
    // per-process secret lives somewhere the user can write.
    let ascii_install = tempfile::tempdir().expect("a temporary ASCII install root");
    let installed_root = ascii_install.path().join("kanai-ai");
    let _junction = AsciiJunction::create(&installed_root, &root);
    let ascii_keys = tempfile::tempdir().expect("a temporary ASCII key root");

    let port = reserve_loopback_port().expect("a reserved loopback port");
    let runtime = kanai_broker::ai_runtime::start_pinned_ai_runtime(
        &manifest_json,
        &receipt_json,
        &installed_root,
        ascii_keys.path(),
        port,
        SUGGESTED_READINESS_DEADLINE,
        &CancellationToken::new(),
    )
    .await
    .expect("the pinned runtime becomes ready");

    assert_eq!(runtime.port(), port);
    assert_eq!(runtime.snapshot().state, RuntimeSupervisorState::Running);
    assert!(runtime.api_key_file().is_some_and(|path| path.is_file()));
    assert!(runtime.api_key().expose().len() >= 32);

    // The key generated here has to be the one the runtime accepts. An
    // unauthenticated health probe cannot show that, so the backend is built from
    // the base URL and the key together: a loopback backend construction is the
    // part of this that a real request would exercise.
    let backend = kanai_broker::LocalOpenAiBackend::new_with_api_key(
        runtime.base_url(),
        runtime.pinned_model_id(),
        runtime.api_key().expose().to_owned(),
    )
    .expect("a loopback backend for the staged runtime");
    assert!(format!("{backend:?}").contains("openai-compatible:"));

    // Readiness only proves the runtime is serving `/health`, which answers 200
    // without a token. A completion is what proves the key this module generated
    // is the one the runtime accepts, that the bearer header reaches it, and that
    // the pinned model actually answers within the product's own bounded
    // deadline. The request is a real rerank over real Japanese candidates, so a
    // wrong decision is a legitimate outcome here; a transport failure is not.
    let decision = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        EnhancementBackend::rerank(
            &backend,
            realistic_rerank_request(),
            CancellationToken::new(),
        ),
    )
    .await
    .expect("the completion must not hang")
    .expect("the pinned runtime must answer an authenticated completion");
    // Recorded rather than asserted: whether a 1.5B general model adopts or
    // abstains on this request is a quality question this test does not settle.
    // What it does settle is that an authenticated completion completed, so the
    // printed line is the evidence of that and not of a quality claim.
    eprintln!(
        "AI_EVIDENCE adopted={} candidates={} metrics={:?}",
        decision.adopted,
        decision.candidates.len(),
        decision.metrics
    );
    // The model is a 1.5B general model, not a reranker trained for this task, so
    // the assertion is about the contract and not about quality: a decision
    // arrived, and it either adopted the baseline or returned only submitted
    // candidates. An invented candidate would be the one unrecoverable failure,
    // because it would put text in front of the user that Mozc never produced.
    if decision.adopted {
        let submitted: Vec<u64> = realistic_rerank_request()
            .candidates
            .iter()
            .map(|candidate| candidate.id)
            .collect();
        for candidate in &decision.candidates {
            assert!(
                submitted.contains(&candidate.id),
                "the model invented candidate id {}, which was never submitted",
                candidate.id
            );
        }
    }

    let key_path = runtime
        .api_key_file()
        .expect("a live key file")
        .to_path_buf();
    assert!(
        key_path.starts_with(ascii_keys.path()),
        "the key file must live under the writable root, not the install root: {key_path:?}"
    );
    runtime.shutdown().await.expect("a confirmed stop");
    assert!(!key_path.exists(), "shutdown must remove the key file");
}

/// A bounded rerank request over real Japanese candidates.
///
/// The deadline is the product's own 250 ms key-path budget, which the real CPU
/// runtime cannot meet on a cold model; the test wraps the call in its own
/// longer bound instead of relaxing the product deadline, so the value under
/// test stays the one the IME actually uses.
fn realistic_rerank_request() -> kanai_broker::CandidateRerankRequest {
    use kanai_broker::{Candidate, CandidateRerankRequest};
    // `SessionId`, `Generation` and `CandidateId` are all `u64` aliases in the
    // protocol, so the ids below are the numeric form the TSF client uses.
    let candidate = |id: u64, text: &str, reading: &str, rank: u16| Candidate {
        id,
        text: text.to_owned(),
        reading: Some(reading.to_owned()),
        rank,
    };
    let mut request = CandidateRerankRequest::new(
        9,
        1,
        vec![
            candidate(1, "会議", "かいぎ", 1),
            candidate(2, "経由", "けいゆ", 2),
            candidate(3, "経営", "けいえい", 3),
        ],
    );
    request.context_before = "明日の".to_owned();
    request.context_after = "を予定しています。".to_owned();
    request
}

/// A directory junction that is detached when it goes out of scope.
///
/// A junction is used rather than a symbolic link because it needs neither
/// elevation nor developer mode, and `RemoveDirectoryW` removes the reparse
/// point without touching the target. PowerShell is used rather than the
/// `mklink` builtin because `cmd` rewrites a non-ASCII argument through the OEM
/// code page, which would mangle exactly the path this needs to preserve.
struct AsciiJunction {
    link: PathBuf,
}

impl AsciiJunction {
    fn create(link: &Path, target: &Path) -> Self {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let script = format!(
            "New-Item -ItemType Junction -Path {} -Target {} -ErrorAction Stop | Out-Null",
            quote_for_powershell(&link.to_string_lossy()),
            quote_for_powershell(&target.to_string_lossy())
        );
        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .expect("PowerShell runs");
        assert!(
            output.status.success(),
            "could not create a junction: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        Self {
            link: link.to_path_buf(),
        }
    }
}

impl Drop for AsciiJunction {
    fn drop(&mut self) {
        // `remove_dir` calls RemoveDirectoryW, which removes the reparse point
        // and leaves the target directory untouched. If this fails, the
        // temporary directory's recursive cleanup could walk into the staged
        // payload, so the failure is reported rather than swallowed.
        if let Err(error) = std::fs::remove_dir(&self.link) {
            eprintln!(
                "warning: could not detach the junction at {:?}: {error}",
                self.link
            );
        }
    }
}

/// Render a value as a single-quoted PowerShell string literal.
///
/// A path holding an unpaired surrogate would be spelled differently by
/// `to_string_lossy`, so the limitation is recorded rather than hidden.
fn quote_for_powershell(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
