//! Composition of the optional pinned local AI runtime: per-process key
//! material, a free loopback port, a bounded readiness probe, and one async
//! entry point that assembles them.
//!
//! This module owns no policy of its own. It exists because four separate
//! pieces already exist and nothing had joined them: [`local_runtime`] builds
//! an argument plan without touching the machine,
//! [`runtime_process_windows`] turns that plan into a real child, and
//! [`runtime_supervisor`] owns the child's lifecycle. Three things were still
//! missing between "a plan exists" and "a model answers": the per-process API
//! key and its file, a port, and proof that the runtime became ready.
//!
//! # Invariants this module is built around
//!
//! * **No model I/O ever happens on a synchronous key-input path.**
//!   [`start_pinned_ai_runtime`] is a startup-path call: it is awaited from the
//!   broker's startup, before the pipe listener serves anything, and every step
//!   inside it is `async`. It performs no synchronous model request, and it is
//!   not reachable from a key handler. The Mozc fast path never calls into this
//!   module.
//! * **The slow path is optional and fails soft.** Every failure below is a
//!   typed [`RuntimeStartupError`] or [`RuntimeProbeError`]. Nothing here
//!   panics, nothing `unwrap`s or `expect`s external input, and no failure
//!   escapes as a panic or a silent success. The caller turns any `Err` into
//!   "keep serving the Mozc baseline".
//! * **The model never receives protected content.** This module handles no
//!   user text at all: no tokens, no logs, no clipboard, no document text, and
//!   no context. It must not grow any code that fetches such content; the
//!   protected-field decision belongs to the broker, upstream of here.
//! * **Nothing is sent to a peer this broker cannot name.** A readiness `200`
//!   only counts when the operating system can prove the server end of the very
//!   socket that carried the request belongs to the child this broker started;
//!   see [`probe_owned_runtime_readiness`] and [`RuntimeOwnership`]. An
//!   unauthenticated listener that won the port race never receives a key, a
//!   preedit, or a candidate.
//! * **The runtime does not outlive the broker.** [`PinnedAiRuntime`] owns the
//!   supervisor and the key file, and its `Drop` releases the supervisor
//!   *before* the key file. See [`PinnedAiRuntime`] for the exact mechanism.
//!
//! # Requirement on the caller: do not block the listener on readiness
//!
//! The composition root **must not** wait for this module before it starts
//! serving the named pipe. The pipe listener has no shutdown path and no
//! interior mutability, so a startup that blocks on the AI path is a startup in
//! which TSF clients can hit `WaitNamedPipeW` timeouts. A measured run of the
//! pinned build reached a serving state in roughly 1.1 s, and a cold page cache
//! is worse than that; blocking the listener for even that long is an
//! availability regression on the Mozc path for a feature that is optional.
//!
//! The pieces are exposed separately for exactly that reason: call
//! [`reserve_loopback_port`] first, start the listener with the Mozc baseline,
//! and only then await [`start_pinned_ai_runtime`] (for example from a
//! `tokio::spawn`), swapping in [`crate::LocalOpenAiBackend`] once it returns
//! `Ok`. [`SUGGESTED_READINESS_DEADLINE`] is a suggested value to pass, not a
//! default this module applies for you.
//!
//! # What the readiness probe does and does not prove
//!
//! [`probe_runtime_readiness`] requires an unauthenticated `200` from
//! `/health`. It deliberately does **not** send the API key: the pinned runtime
//! answers `/health` without a token (see [`crate::local_model`]), so a token
//! would prove nothing, and a probe that carries the secret is a probe that can
//! leak it.
//!
//! # Peer ownership: `Ready` is not enough on its own
//!
//! A `200` from `/health` proves only that *something* answered on a port this
//! process once reserved. [`reserve_loopback_port`] binds and releases, so
//! between that release and the runtime's own `bind` another process on the
//! machine can take the port, and any answer to an unauthenticated probe would
//! then be indistinguishable from the runtime's. The production path therefore
//! uses [`probe_owned_runtime_readiness`], which additionally requires
//! [`RuntimeOwnership`] to prove - through the supervisor, through the process
//! adapter, and through the operating system's own TCP connection table - that
//! the server end of the connected socket is the child this broker started. It
//! fails closed: a connection that cannot be attributed is an error, not a
//! retry, so an unowned listener gets no further chance to be probed.
//!
//! The same proof is available after startup through
//! [`RuntimeOwnership::verify_endpoint`], which is what a caller uses to gate
//! the request that carries the bearer token and the user's text.
//!
//! A weaker probe was possible and is rejected here: connecting to the port and
//! treating an open socket as "ready". That only proves something is listening,
//! which a runtime that is still loading the 1.1 GB weight also satisfies, so it
//! would hand the caller a backend that fails its first request. The
//! implementation therefore requires an answered HTTP request, and it keeps the
//! two failure modes apart: [`RuntimeReadiness::NotListening`] (nothing accepted
//! a connection) and [`RuntimeReadiness::NotServing`] (something answered, but
//! not `200`).
//!
//! What `Ready` still does *not* prove: that a completion will succeed. No test
//! in this repository exercises `/v1/chat/completions` against the pinned
//! build, so treat `Ready` as "the slow path is worth enabling", not as "the
//! model answered".
//!
//! # Platform
//!
//! The key file is created with a Win32 access control list that grants full
//! access to exactly one principal: the user (or `SYSTEM`) that runs the broker.
//! The DACL is protected (`D:P(...)`), so nothing is inherited from the parent
//! directory, which is what actually excludes other users - `Program Files`
//! would otherwise hand the file an inherited `Users`-read ACE.
//!
//! [`start_pinned_ai_runtime`] is Windows-only because the pinned runtime is a
//! Windows build. The key, port, probe, and [`start_planned_ai_runtime`] pieces
//! compile everywhere; on a platform other than Windows the key generator
//! reports [`RuntimeStartupError::RandomSourceUnavailable`] rather than
//! substituting a weaker source.
//!
//! # Known limitation: where the key file can be written
//!
//! [`local_runtime`] requires the key-file path to be an installed-relative path
//! resolved against the same root as the pinned executable and the model, so
//! the key file lands inside the install root. If that root is not writable by
//! the account running the broker - `C:\Program Files` is not - key material
//! cannot be created, the start fails with
//! [`RuntimeStartupError::KeyFileCreateFailed`], and the AI path stays off. This
//! module cannot fix that: the reviewed plan has no slot for a key file outside
//! the install root. Resolving it needs a change to
//! [`crate::local_runtime`] / [`crate::runtime_process_windows`], which are not
//! part of this work order.

use std::fmt;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::watch;

use crate::broker::CancellationToken;
use crate::local_runtime::{PINNED_MODEL_ID, RUNTIME_LOOPBACK_HOST, RuntimeLaunchPlan};
use crate::runtime_supervisor::{
    RuntimeProcess, RuntimeStateSnapshot, RuntimeSupervisor, RuntimeSupervisorConfig,
    RuntimeSupervisorState, TokioRuntimeClock,
};

/// Random bytes in a per-process API key: 256 bits, well above any brute-force
/// or collision concern for a loopback-only token.
pub const RUNTIME_API_KEY_BYTES: usize = 32;
/// Length of the hex-encoded key, which is what travels as the bearer token.
pub const RUNTIME_API_KEY_TEXT_BYTES: usize = RUNTIME_API_KEY_BYTES * 2;

/// Installed-relative path of the per-process key file.
///
/// It resolves against the same install root as the pinned executable and the
/// model, which is a limitation of the reviewed plan rather than a choice here;
/// see "Known limitation" in the module documentation. `local_runtime` rejects
/// a key path that equals the model or server path, and this value collides
/// with neither.
pub const RUNTIME_API_KEY_FILE_RELATIVE: &str = "runtime/api-key.txt";

/// Delay between readiness attempts.
pub const READINESS_POLL_INTERVAL: Duration = Duration::from_millis(100);
/// Longest a wait between attempts sleeps before re-reading the cancellation
/// flag.
///
/// [`crate::CancellationToken`] is a flag rather than a future, so a
/// cancellation cannot interrupt a sleep directly. Sleeping in slices of at
/// most this length bounds how long a cancelled probe can keep polling.
pub const READINESS_CANCELLATION_SLICE: Duration = Duration::from_millis(25);
/// Upper bound accepted for a readiness deadline.
///
/// The deadline is a parameter, not a hidden constant, so a caller can widen it
/// for a cold cache; this bound is what keeps the probe finite when a caller
/// passes something unreasonable.
pub const MAX_READINESS_DEADLINE: Duration = Duration::from_secs(300);
/// A suggested readiness deadline, not a default this module applies.
///
/// One measured run of the pinned build reached a serving state in roughly
/// 1.1 s. A deadline well under a second would fail that run, and a cold page
/// cache is slower, so a caller that wants a comfortable margin should pass at
/// least this value - and should pass it explicitly, because the point of the
/// parameter is that the caller chooses.
pub const SUGGESTED_READINESS_DEADLINE: Duration = Duration::from_secs(30);
/// Upper bound on the response bytes the probe reads while looking for a
/// status line. Anything longer is treated as "not serving".
const MAX_STATUS_LINE_BYTES: usize = 128;
/// Upper bound on one ownership check against the loopback endpoint.
///
/// The check is a loopback connect plus a lookup in the operating system's
/// connection table, which normally completes in well under a millisecond. A
/// check that cannot complete inside this bound is treated as unproven, because
/// this runs on the request path and a slow confirmation must not become a slow
/// conversion. The bound is a deliberate trade: an unproven owner falls back to
/// the Mozc baseline, which is the safe direction to fail.
pub const OWNERSHIP_VERIFY_TIMEOUT: Duration = Duration::from_millis(200);

/// What one bounded readiness poll concluded.
///
/// [`Self::NotListening`] and [`Self::NotServing`] are deliberately distinct: a
/// runtime that never opened its socket and a runtime that answered with
/// something other than `200` are different operator problems.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeReadiness {
    /// `/health` answered `200` without a token.
    Ready,
    /// Something accepted a connection but did not answer `200`.
    NotServing,
    /// Nothing accepted a connection on loopback.
    NotListening,
}

/// Failures of the bounded readiness poll itself.
///
/// A runtime that is merely not ready yet is not an error here: it is
/// [`RuntimeReadiness`]. These variants are the probe giving up, being
/// cancelled, or being handed an unusable request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RuntimeProbeError {
    #[error("AI runtime readiness deadline elapsed before the runtime answered")]
    DeadlineElapsed {
        /// The last thing observed, so a caller can report "never listened" and
        /// "answered with a non-200 status" differently.
        last: RuntimeReadiness,
    },
    #[error("AI runtime readiness probe was cancelled")]
    Cancelled,
    #[error("AI runtime readiness port must be nonzero")]
    InvalidPort,
    #[error("AI runtime readiness deadline must be nonzero and at most 300 seconds")]
    InvalidDeadline,
    /// A peer answered, and the operating system could not prove it is the child
    /// this broker started.
    ///
    /// This is the time-of-check/time-of-use window of
    /// [`reserve_loopback_port`] turning hostile: another process took the
    /// reserved port and answered. It is reported instead of retried, because
    /// retrying only offers an unowned listener another chance to be sent a
    /// request, and nothing about the second attempt would be more trustworthy.
    #[error("AI runtime readiness peer is not the supervised child process")]
    PeerOwnershipUnproven,
}

/// A content-free projection of the Windows process adapter's typed refusals.
///
/// The adapter's own variants are Windows-only, and this module's error type is
/// not, so the reason is mirrored here instead of embedded. Every variant is a
/// condition with no path, command output, or key material in it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ProcessRefusal {
    #[error("the pinned executable is missing or not a file")]
    MissingExecutable,
    #[error("the pinned model weights are missing or not a file")]
    MissingModel,
    #[error("the API-key file is missing or not a file")]
    MissingKeyFile,
    #[error("the resolved command line is not ASCII")]
    NonAsciiCommandPath,
    #[error("the reviewed argument plan does not match the launch shape")]
    ArgumentPlanMismatch,
}

#[cfg(windows)]
impl From<crate::runtime_process_windows::WindowsProcessError> for ProcessRefusal {
    fn from(error: crate::runtime_process_windows::WindowsProcessError) -> Self {
        use crate::runtime_process_windows::WindowsProcessError as Adapter;
        match error {
            Adapter::MissingExecutable => Self::MissingExecutable,
            Adapter::MissingModel => Self::MissingModel,
            Adapter::MissingKeyFile => Self::MissingKeyFile,
            Adapter::NonAsciiCommandPath => Self::NonAsciiCommandPath,
            Adapter::ArgumentPlanMismatch => Self::ArgumentPlanMismatch,
        }
    }
}

/// Every way starting the optional local AI runtime can fail.
///
/// All variants are content-free: no key material, no path, no command line, and
/// no model output. A caller that receives one of them keeps the Mozc baseline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RuntimeStartupError {
    #[error("AI runtime port must be nonzero")]
    PortRejected,
    #[error("AI runtime launch plan is not the reviewed pinned plan")]
    LaunchPlanInvalid,
    #[error("AI runtime API-key path is not usable under the install root")]
    KeyFilePathRejected,
    #[error("AI runtime could not obtain cryptographically random key material")]
    RandomSourceUnavailable,
    #[error("AI runtime could not create its API-key file")]
    KeyFileCreateFailed,
    #[error("AI runtime could not remove its API-key file")]
    KeyFileRemoveFailed,
    #[error("AI runtime launch was refused: {0}")]
    ProcessRefused(#[from] ProcessRefusal),
    #[error("AI runtime supervisor policy was rejected")]
    SupervisorConfigInvalid,
    #[error("AI runtime process could not be started")]
    SupervisorStartFailed,
    #[error("AI runtime stop was not confirmed")]
    SupervisorStopFailed,
    #[error("AI runtime readiness probe failed: {0}")]
    ReadinessProbe(#[from] RuntimeProbeError),
    #[error("AI runtime start was cancelled")]
    Cancelled,
}

/// A per-process API key.
///
/// The value is generated here, handed to the caller once, and never printed.
/// There is no `Display` impl, so `{}` cannot leak it, and the `Debug` impl
/// reports nothing at all. `Drop` overwrites the buffer on a best-effort basis;
/// see [`Self::expose`] for what that does and does not promise.
pub struct RuntimeApiKey {
    /// Lowercase hexadecimal, so the value is safe in an `Authorization`
    /// header and contains nothing a header could be split on.
    bytes: Vec<u8>,
}

impl RuntimeApiKey {
    /// Generate a fresh key from the operating system CSPRNG.
    ///
    /// There is no fallback to a weaker source. When the platform RNG cannot be
    /// reached this fails with
    /// [`RuntimeStartupError::RandomSourceUnavailable`] rather than returning a
    /// guessable value.
    pub fn generate() -> Result<Self, RuntimeStartupError> {
        let mut random = vec![0_u8; RUNTIME_API_KEY_BYTES];
        fill_random(&mut random)?;
        Ok(Self {
            bytes: to_hexadecimal(&random),
        })
    }

    /// The key value, for handing to `LocalOpenAiBackend::new_with_api_key`.
    ///
    /// This borrow is the only way to obtain the value. The result must go
    /// straight into the backend constructor: it must not be logged, formatted,
    /// placed in a URL, placed in a process argument, or stored anywhere that
    /// outlives the backend. The backend copies it, so a caller does not need to
    /// keep a second copy.
    ///
    /// The buffer is zeroed on drop, which is best effort only: the compiler may
    /// elide a write it can prove is dead, the allocator may have copied the
    /// bytes, and the operating system may have paged them. A guarantee here
    /// would need a `zeroize` dependency, which this work order does not permit
    /// adding.
    #[must_use]
    pub fn expose(&self) -> &str {
        // The value is produced by this module as ASCII hexadecimal and `bytes`
        // is private, so the `Err` arm is unreachable. It returns an empty
        // borrow rather than panicking because a secret must not turn a broken
        // internal invariant into a crash on the broker's startup path; an empty
        // key is then rejected by the backend constructor as a typed error.
        std::str::from_utf8(&self.bytes).unwrap_or("")
    }

    /// Length of the key value in bytes.
    #[must_use]
    pub fn text_len(&self) -> usize {
        self.bytes.len()
    }
}

impl fmt::Debug for RuntimeApiKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // A derived `Debug` would print the value. Diagnostics may report that a
        // key exists; they may not report it.
        formatter.write_str("RuntimeApiKey(<redacted>)")
    }
}

impl Drop for RuntimeApiKey {
    fn drop(&mut self) {
        self.bytes.fill(0);
    }
}

/// Lowercase hexadecimal, which is what a bearer token can carry verbatim.
///
/// Hex rather than a base64 or a raw byte string because a header value has to be
/// free of anything that could split it, and because a value that is
/// self-evidently printable is easier to keep out of a log by accident.
fn to_hexadecimal(bytes: &[u8]) -> Vec<u8> {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut hexadecimal = Vec::with_capacity(bytes.len() * 2);
    for byte in bytes {
        hexadecimal.push(DIGITS[usize::from(byte >> 4)]);
        hexadecimal.push(DIGITS[usize::from(byte & 0x0f)]);
    }
    hexadecimal
}

/// The per-process API-key file on disk.
///
/// The file is created with an access control list that excludes other users,
/// holds exactly the key value and no trailing newline, and is removed when this
/// value is dropped. The key is not read back through this type after creation.
pub struct RuntimeApiKeyFile {
    /// `None` once the file has been removed, which makes removal idempotent
    /// across the explicit [`Self::remove`] call and `Drop`.
    path: Option<PathBuf>,
}

impl RuntimeApiKeyFile {
    /// Write `key` to `path` with a restrictive access control list.
    ///
    /// The path must be ASCII: it becomes part of the runtime's command line,
    /// and the pinned build is refused rather than started when that command
    /// line is not ASCII. A non-ASCII path is rejected here, before any byte is
    /// written, so a rejected start never leaves key material behind.
    ///
    /// The file is written without a trailing newline. How the pinned build
    /// treats the file's trailing whitespace was not verified here, and an
    /// ending newline is the one form that cannot work either way: a runtime
    /// that does not trim it would expect a key no header can carry, and a
    /// runtime that does trim it accepts this form unchanged.
    pub fn create(path: &Path, key: &RuntimeApiKey) -> Result<Self, RuntimeStartupError> {
        if !path.to_str().is_some_and(str::is_ascii) {
            return Err(RuntimeStartupError::KeyFilePathRejected);
        }
        // The key file lives under a per-user writable root that nothing else
        // creates, so its directory chain has to exist before `CreateFileW`
        // will accept the path. Only the parents of the file itself are made:
        // the root belongs to the caller.
        if let Some(parent) = path.parent() {
            create_private_directories(parent)?;
        }
        create_restricted_file(path, key.expose().as_bytes())
    }

    /// The path the key file occupies.
    #[must_use]
    pub fn path(&self) -> &Path {
        // `path` is only `None` after removal, and a removed handle is consumed
        // by `remove`, so this is total. Returning an empty path would hide the
        // mistake, and the invariant is local to this type.
        self.path.as_deref().unwrap_or(Path::new(""))
    }

    /// Remove the key file now and report whether the removal succeeded.
    ///
    /// Dropping the value does this too, but cannot report a failure. An operator
    /// that needs to know whether the secret is gone calls this and checks.
    pub fn remove(mut self) -> Result<(), RuntimeStartupError> {
        self.remove_inner()
            .map_err(|_| RuntimeStartupError::KeyFileRemoveFailed)
    }

    fn remove_inner(&mut self) -> std::io::Result<()> {
        let Some(path) = self.path.take() else {
            return Ok(());
        };
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            // A concurrent `remove` already did the work, and the goal is
            // "no file", not "this call deleted it".
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => {
                // Keep the path so `Drop` can try again.
                self.path = Some(path);
                Err(error)
            }
        }
    }
}

impl fmt::Debug for RuntimeApiKeyFile {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // A derived `Debug` would print an absolute path, which embeds the
        // Windows account name and the install layout. Report the file name only.
        let name = self
            .path
            .as_deref()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .unwrap_or("<unprintable>");
        formatter
            .debug_struct("RuntimeApiKeyFile")
            .field("file_name", &name)
            .field("removed", &self.path.is_none())
            .finish()
    }
}

impl Drop for RuntimeApiKeyFile {
    fn drop(&mut self) {
        // Best effort and silent: `Drop` cannot report, and panicking here would
        // take down a broker whose input path is already finished. A caller that
        // must know uses `remove`.
        let _ = self.remove_inner();
    }
}

/// Reserve a free loopback port by binding `127.0.0.1:0`, reading the assigned
/// port, and releasing the socket.
///
/// The bind is IPv4 loopback only and is never widened to `0.0.0.0`: a runtime
/// reachable from the local network is not an acceptable default for a
/// component that is meant to be reachable only from this process.
///
/// # The time-of-check/time-of-use window
///
/// Releasing the socket before the runtime binds it is unavoidable with the
/// current seams. The reviewed plan takes a port number, not a socket, so there
/// is a window between this function returning and `llama-server` calling `bind`
/// in which another process on the machine can take the port. No amount of care
/// in this function closes that window; only handing the live socket to the
/// runtime would, and that needs a change to the reviewed plan.
///
/// What a lost race costs, precisely: the runtime fails to bind and exits; the
/// supervisor reports a typed start failure through its own state machine; the
/// readiness probe sees nothing listening and gives up at its deadline; the
/// caller receives a typed error and keeps the Mozc baseline. Nothing user
/// visible degrades, the race is not retried, and the failure is diagnosable
/// from the supervisor snapshot.
pub fn reserve_loopback_port() -> Result<u16, RuntimeStartupError> {
    Ok(reserve_loopback_address()?.port())
}

/// The loopback socket address whose port was just released.
///
/// The address is returned so a caller can prove the bind was loopback; the
/// port is what the launch plan needs.
pub fn reserve_loopback_address() -> Result<SocketAddr, RuntimeStartupError> {
    let listener = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .map_err(|_| RuntimeStartupError::PortRejected)?;
    let address = listener
        .local_addr()
        .map_err(|_| RuntimeStartupError::PortRejected)?;
    // The listener is dropped here, releasing the port. See the TOCTOU note on
    // `reserve_loopback_port`.
    drop(listener);
    if address.port() == 0 {
        return Err(RuntimeStartupError::PortRejected);
    }
    Ok(address)
}

/// Poll the pinned runtime's `/health` endpoint until it answers `200`, the
/// deadline elapses, or the caller cancels.
///
/// Bounded by construction: every socket operation is wrapped in the time left
/// before `deadline`, so the call cannot hang past it, and `deadline` itself is
/// rejected unless it is nonzero and at most [`MAX_READINESS_DEADLINE`]. A zero
/// deadline is refused rather than honoured because it could only ever observe a
/// socket that is *already* accepting, so it cannot tell ready from not-ready
/// and would report a false negative.
///
/// The poll is cancellable through a flag, so a cancellation is observed within
/// [`READINESS_CANCELLATION_SLICE`] rather than at the next attempt boundary.
/// That bound covers the connected phase as well: a peer that accepts and then
/// stalls cannot hold the probe for the rest of the deadline.
///
/// The request carries no `Authorization` header and no key: the pinned runtime
/// answers `/health` without a token, and a probe that carries the secret is a
/// probe that can leak it.
///
/// # This function does not prove peer ownership
///
/// It is the transport half of readiness only, kept for diagnostics and for the
/// cases where a caller has no supervisor handle. A caller that is about to let
/// a model receive the bearer token and the user's text must use
/// [`probe_owned_runtime_readiness`] instead: a `200` from a process that won
/// the port race is indistinguishable from the runtime's.
pub async fn probe_runtime_readiness(
    port: u16,
    deadline: Duration,
    cancellation: &CancellationToken,
) -> Result<RuntimeReadiness, RuntimeProbeError> {
    probe_until_ready(port, deadline, cancellation, None).await
}

/// [`probe_runtime_readiness`], with the peer-ownership requirement.
///
/// `Ready` is returned only when the same socket that carried the `200` is
/// proven by `ownership` to have its server end in the child this broker
/// started. A connection that cannot be attributed returns
/// [`RuntimeProbeError::PeerOwnershipUnproven`] immediately: this is the port
/// race being lost, not a runtime that is still loading.
pub async fn probe_owned_runtime_readiness(
    port: u16,
    deadline: Duration,
    cancellation: &CancellationToken,
    ownership: &RuntimeOwnership,
) -> Result<RuntimeReadiness, RuntimeProbeError> {
    probe_until_ready(port, deadline, cancellation, Some(ownership)).await
}

async fn probe_until_ready(
    port: u16,
    deadline: Duration,
    cancellation: &CancellationToken,
    ownership: Option<&RuntimeOwnership>,
) -> Result<RuntimeReadiness, RuntimeProbeError> {
    if port == 0 {
        return Err(RuntimeProbeError::InvalidPort);
    }
    if deadline.is_zero() || deadline > MAX_READINESS_DEADLINE {
        return Err(RuntimeProbeError::InvalidDeadline);
    }
    let end = Instant::now() + deadline;
    loop {
        if cancellation.is_cancelled() {
            return Err(RuntimeProbeError::Cancelled);
        }
        let last = probe_once(port, end, cancellation, ownership).await?;
        if last == RuntimeReadiness::Ready {
            return Ok(RuntimeReadiness::Ready);
        }
        if !sleep_until_next_attempt(end, cancellation).await {
            return Err(RuntimeProbeError::Cancelled);
        }
        if Instant::now() >= end {
            return Err(RuntimeProbeError::DeadlineElapsed { last });
        }
    }
}

/// One connect, one ownership proof, one request, one status line.
///
/// `ownership` is what makes the request trustworthy rather than merely
/// answered: it is consulted with this connection's own endpoint pair, so a
/// proof about some other socket cannot stand in for this one, and the socket is
/// not reconnected afterwards.
async fn probe_once(
    port: u16,
    end: Instant,
    cancellation: &CancellationToken,
    ownership: Option<&RuntimeOwnership>,
) -> Result<RuntimeReadiness, RuntimeProbeError> {
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = match connect_sliced(&address, end, cancellation).await {
        Some(stream) => stream,
        None => return Ok(RuntimeReadiness::NotListening),
    };
    if let Some(ownership) = ownership {
        let (Ok(local), Ok(peer)) = (stream.local_addr(), stream.peer_addr()) else {
            return Err(RuntimeProbeError::PeerOwnershipUnproven);
        };
        if !ownership.verify_connection(local, peer).await {
            return Err(RuntimeProbeError::PeerOwnershipUnproven);
        }
    }
    let request = health_request(port);
    // A timed-out write leaves a half-sent request on a socket this probe is
    // about to drop, so re-arming would corrupt it instead of helping; the slice
    // bound is only there so a wedged peer cannot hold the probe.
    if tokio::time::timeout(
        remaining(end).min(READINESS_CANCELLATION_SLICE),
        stream.write_all(request.as_bytes()),
    )
    .await
    .is_err()
    {
        return Ok(RuntimeReadiness::NotServing);
    }
    read_status_line(&mut stream, end, cancellation).await
}

/// Connect, observing the cancellation flag while the connect is pending.
///
/// `None` means "not connected within the deadline", which the caller reports as
/// [`RuntimeReadiness::NotListening`]: a loopback connect to a listening socket
/// completes immediately, so the only realistic cause is that nothing is there.
async fn connect_sliced(
    address: &SocketAddr,
    end: Instant,
    cancellation: &CancellationToken,
) -> Option<TcpStream> {
    loop {
        if cancellation.is_cancelled() || Instant::now() >= end {
            return None;
        }
        let slice = remaining(end).min(READINESS_CANCELLATION_SLICE);
        match tokio::time::timeout(slice, TcpStream::connect(address)).await {
            Ok(Ok(stream)) => return Some(stream),
            Ok(Err(_)) => return None,
            // The slice elapsed rather than the connect finishing. Re-arm
            // rather than give up, so a slow-but-successful connect is not
            // reported as nothing listening, and a cancellation is still seen
            // within one slice.
            Err(_) => {}
        }
    }
}

/// Read the status line in cancellation-observable slices.
///
/// The read is re-armed on every slice expiry rather than abandoned, so a peer
/// that answers slowly is still read while a peer that never answers cannot hold
/// the probe past the next slice. `TcpStream::read` is cancellation safe, so
/// re-arming cannot lose a byte that was already accepted.
async fn read_status_line(
    stream: &mut TcpStream,
    end: Instant,
    cancellation: &CancellationToken,
) -> Result<RuntimeReadiness, RuntimeProbeError> {
    let mut buffer = [0_u8; MAX_STATUS_LINE_BYTES];
    let mut filled = 0_usize;
    loop {
        if cancellation.is_cancelled() {
            return Err(RuntimeProbeError::Cancelled);
        }
        let Some(window) = buffer.get_mut(filled..) else {
            return Ok(RuntimeReadiness::NotServing);
        };
        let full = window.len();
        let slice = remaining(end).min(READINESS_CANCELLATION_SLICE);
        match tokio::time::timeout(slice, stream.read(window)).await {
            Ok(Ok(0)) => return Ok(classify_status_line(&buffer[..filled])),
            Ok(Ok(read)) => {
                filled += read;
                if let Some(end_of_line) = find_status_line_end(&buffer[..filled]) {
                    return Ok(classify_status_line(&buffer[..end_of_line]));
                }
                if filled == full {
                    return Ok(RuntimeReadiness::NotServing);
                }
            }
            // A reset connection means something was there and is no longer
            // answering; that is a serving-but-wrong state, not a closed port.
            // A slice or deadline expiry is the same class: no usable answer.
            Ok(Err(_)) | Err(_) => return Ok(RuntimeReadiness::NotServing),
        }
    }
}

fn remaining(end: Instant) -> Duration {
    end.saturating_duration_since(Instant::now())
}

/// Sleep until the next attempt is due, in cancellation-observable slices.
///
/// Returns `false` when the caller cancelled instead of the wait completing.
async fn sleep_until_next_attempt(end: Instant, cancellation: &CancellationToken) -> bool {
    let mut left = READINESS_POLL_INTERVAL.min(remaining(end));
    while !left.is_zero() {
        if cancellation.is_cancelled() {
            return false;
        }
        let slice = left.min(READINESS_CANCELLATION_SLICE);
        tokio::time::sleep(slice).await;
        left -= slice;
    }
    !cancellation.is_cancelled()
}

/// The probe's request. `Connection: close` keeps the answer in one read, and
/// the `Host` header is required by HTTP/1.1.
fn health_request(port: u16) -> String {
    format!(
        "GET /health HTTP/1.1\r\nHost: {RUNTIME_LOOPBACK_HOST}:{port}\r\nUser-Agent: kanai-broker-readiness\r\nConnection: close\r\n\r\n"
    )
}

fn find_status_line_end(bytes: &[u8]) -> Option<usize> {
    bytes.windows(2).position(|pair| pair == b"\r\n")
}

fn classify_status_line(line: &[u8]) -> RuntimeReadiness {
    let mut fields = line.split(|byte| *byte == b' ');
    let version = fields.next().unwrap_or(&[]);
    let status = fields.next().unwrap_or(&[]);
    if version.starts_with(b"HTTP/1.") && status == b"200".as_slice() {
        RuntimeReadiness::Ready
    } else {
        RuntimeReadiness::NotServing
    }
}

/// A secret-free handle that can re-prove who owns the loopback endpoint.
///
/// It holds the supervisor - the only thing in this crate that knows the child
/// process identity - and the port the reviewed plan asked that child to bind.
/// It carries no key material, no path, and no command line, so it can be cloned
/// into a request path.
///
/// Holding this value proves nothing by itself: [`Self::verify_connection`] and
/// [`Self::verify_endpoint`] are what consult the operating system's TCP
/// connection table, and both fail closed. Use them to gate every request that
/// carries the bearer token or the user's text.
#[derive(Clone)]
pub struct RuntimeOwnership {
    supervisor: Arc<RuntimeSupervisor>,
    port: u16,
}

impl RuntimeOwnership {
    /// Prove the server end of an already established connection.
    ///
    /// `peer` must be this handle's endpoint, and the connection must be one the
    /// caller still holds: a proof about a socket that has been closed, or about
    /// a different connection to the same port, says nothing about the bytes
    /// about to be written.
    pub async fn verify_connection(&self, local: SocketAddr, peer: SocketAddr) -> bool {
        if peer != SocketAddr::from((Ipv4Addr::LOCALHOST, self.port)) {
            return false;
        }
        self.supervisor.verify_connection(local, peer).await
    }

    /// Prove that the configured endpoint is still answered by the child.
    ///
    /// A fresh loopback connection is opened, its own endpoint pair is taken, and
    /// that socket is put to the ownership check. No bytes are written: the proof
    /// is the operating system's connection table, not the peer's cooperation.
    ///
    /// # What this does not prove
    ///
    /// The socket used here is not the socket the caller will send its request
    /// on, so a takeover that completes in the gap between the two connections is
    /// not excluded. What it does prove is that a process other than the child
    /// cannot be the endpoint's current owner: such a process accepts this
    /// connection, the table row names it, and the check fails. Binding the
    /// *request* itself to a verified socket needs a seam in the HTTP client,
    /// which lives outside this module.
    pub async fn verify_endpoint(&self) -> bool {
        let address = SocketAddr::from((Ipv4Addr::LOCALHOST, self.port));
        let Ok(Ok(stream)) =
            tokio::time::timeout(OWNERSHIP_VERIFY_TIMEOUT, TcpStream::connect(address)).await
        else {
            return false;
        };
        let (Ok(local), Ok(peer)) = (stream.local_addr(), stream.peer_addr()) else {
            return false;
        };
        self.verify_connection(local, peer).await
    }

    /// Watch lifecycle state changes, for a caller that waits on the runtime.
    ///
    /// The returned receiver reports every published state, so a caller does not
    /// have to poll; a closed channel means the supervisor is gone, which is the
    /// same answer as a state that is not running.
    pub fn subscribe_states(&self) -> watch::Receiver<RuntimeStateSnapshot> {
        self.supervisor.subscribe_states()
    }

    /// The latest typed lifecycle snapshot.
    #[must_use]
    pub fn snapshot(&self) -> RuntimeStateSnapshot {
        self.supervisor.snapshot()
    }

    /// Whether the child is live right now.
    ///
    /// Every state other than [`RuntimeSupervisorState::Running`] means the port
    /// is not being served by this broker's child, so a caller must stop sending
    /// to it rather than wait for a request to time out.
    #[must_use]
    pub fn is_running(&self) -> bool {
        self.supervisor.snapshot().state == RuntimeSupervisorState::Running
    }
}

impl fmt::Debug for RuntimeOwnership {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The port is already in the child's command line and the snapshot is a
        // typed enum, so neither is a path, a key, or user text.
        formatter
            .debug_struct("RuntimeOwnership")
            .field("port", &self.port)
            .field("state", &self.supervisor.snapshot().state)
            .finish()
    }
}

/// A started, ready, supervised local AI runtime and everything that must die
/// with it.
///
/// The handle owns three things: the [`RuntimeSupervisor`] that owns the child,
/// the [`RuntimeApiKey`] the caller needs for
/// [`crate::LocalOpenAiBackend::new_with_api_key`], and the
/// [`RuntimeApiKeyFile`] whose removal takes the secret off disk.
///
/// The supervisor is deliberately **not** handed out as an `Arc`, so this handle
/// is its only owner. That is what makes the `Drop` guarantee below real rather
/// than advisory: [`RuntimeSupervisor`]'s own `Drop` signals its monitor task,
/// the monitor issues a forced stop, and the process adapter's kill-on-close job
/// object terminates the child.
///
/// # Release order
///
/// `Drop` releases the supervisor first and removes the key file second, so no
/// child can ever be started against a key file that has already been taken off
/// disk. The supervisor's `Drop` sets the closed flag and publishes the shutdown
/// request, and the monitor reads that before it starts a replacement, so the
/// window a removed key file used to open - a restart landing after the removal -
/// is closed at its source. `WindowsRuntimeProcess::start` re-validates the key
/// file on every start as the second, independent barrier against the same
/// outcome.
///
/// [`Self::shutdown`] is the explicit form: it awaits a confirmed stop, then
/// releases both, and reports whether the stop was confirmed. `Drop` cannot
/// await, so it does not report; the operating system still terminates the child
/// through the job object when the broker exits, including on `abort` or power
/// loss, except for the narrow window `runtime_process_windows` documents
/// between process creation and job assignment.
pub struct PinnedAiRuntime {
    supervisor: Option<Arc<RuntimeSupervisor>>,
    key: RuntimeApiKey,
    key_file: Option<RuntimeApiKeyFile>,
    base_url: String,
    port: u16,
}

impl PinnedAiRuntime {
    /// Authenticate the connected server endpoint before any request bytes.
    /// The caller must use this exact connected socket, without reconnects.
    pub async fn verify_connection(&self, local: SocketAddr, peer: SocketAddr) -> bool {
        if peer != SocketAddr::from((Ipv4Addr::LOCALHOST, self.port)) {
            return false;
        }
        match self.supervisor.as_ref() {
            Some(supervisor) => supervisor.verify_connection(local, peer).await,
            None => false,
        }
    }

    /// A secret-free handle that re-proves the endpoint's owner on demand.
    ///
    /// `None` once the supervisor has been released. The handle deliberately
    /// carries no key: a request gate needs the ownership proof, not the secret.
    #[must_use]
    pub fn ownership(&self) -> Option<RuntimeOwnership> {
        self.supervisor.as_ref().map(|supervisor| RuntimeOwnership {
            supervisor: Arc::clone(supervisor),
            port: self.port,
        })
    }
    /// The loopback base URL for the runtime, for
    /// `LocalOpenAiBackend::new_with_api_key`.
    #[must_use]
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// The loopback port the runtime was asked to bind.
    #[must_use]
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The per-process API key. See [`RuntimeApiKey::expose`] for the rules on
    /// using it.
    #[must_use]
    pub fn api_key(&self) -> &RuntimeApiKey {
        &self.key
    }

    /// The key file's path while it exists, or `None` once it has been removed.
    #[must_use]
    pub fn api_key_file(&self) -> Option<&Path> {
        self.key_file.as_ref().map(RuntimeApiKeyFile::path)
    }

    /// The identifier the pinned manifest gives the weight.
    ///
    /// Whether the pinned runtime validates the `model` field of a request was
    /// not verified here, so this is a manifest identifier and not a promise
    /// about what the server accepts.
    #[must_use]
    pub fn pinned_model_id(&self) -> &'static str {
        PINNED_MODEL_ID
    }

    /// The supervisor's latest typed lifecycle snapshot.
    #[must_use]
    pub fn snapshot(&self) -> RuntimeStateSnapshot {
        self.supervisor
            .as_ref()
            .map_or_else(released_snapshot, |supervisor| supervisor.snapshot())
    }

    /// Stop the runtime, then release the key material and the key file.
    ///
    /// The stop is a forced stop because the pinned build exposes no
    /// cooperative shutdown for a windowless process. The key file is removed
    /// and the supervisor released whether or not the stop was confirmed, so a
    /// stop failure cannot leave a secret behind.
    pub async fn shutdown(self) -> Result<(), RuntimeStartupError> {
        let outcome = match self.supervisor.as_ref() {
            Some(supervisor) => supervisor
                .force_stop()
                .await
                .map_err(|_| RuntimeStartupError::SupervisorStopFailed),
            None => Ok(()),
        };
        drop(self);
        outcome
    }
}

impl fmt::Debug for PinnedAiRuntime {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PinnedAiRuntime")
            .field("base_url", &self.base_url)
            .field("port", &self.port)
            .field("api_key", &"<redacted>")
            .field("api_key_file_present", &self.key_file.is_some())
            .field("state", &self.snapshot().state)
            .finish()
    }
}

impl Drop for PinnedAiRuntime {
    fn drop(&mut self) {
        // The supervisor goes first. Dropping the last `Arc<RuntimeSupervisor>`
        // sets its closed flag and publishes the shutdown request, which is what
        // stops the monitor from starting a replacement; only then is the key
        // taken off disk. The opposite order left a window in which a restart
        // could be prepared against a key file that no longer existed, and a
        // runtime started that way is a loopback model server with no
        // authentication at all.
        drop(self.supervisor.take());
        if let Some(key_file) = self.key_file.take() {
            let _ = key_file.remove();
        }
    }
}

/// The snapshot a handle reports once its supervisor has been released: no
/// child, nothing in flight, and no error, because a released runtime is an
/// expected end state rather than a failure.
fn released_snapshot() -> RuntimeStateSnapshot {
    RuntimeStateSnapshot {
        state: RuntimeSupervisorState::Idle,
        automatic_restarts: 0,
        last_error: None,
    }
}

/// Start the pinned runtime from an already-built, reviewed launch plan, with an
/// injected process adapter.
///
/// This is the same chain [`start_pinned_ai_runtime`] runs, minus building the
/// plan from JSON and minus choosing the Windows process adapter. It exists so
/// the composition chain can be exercised without a real `llama-server` process
/// and without the 1.1 GB weight: a caller supplies any
/// `Arc<dyn RuntimeProcess>`, including a fake, and the key file, the
/// supervisor, the readiness probe, and the cleanup behaviour under test are the
/// production ones.
///
/// `readiness_deadline` is a parameter, never a default; see
/// [`SUGGESTED_READINESS_DEADLINE`] for a suggested value.
pub async fn start_planned_ai_runtime(
    plan: RuntimeLaunchPlan,
    key_file_root: &Path,
    process: Arc<dyn RuntimeProcess>,
    readiness_deadline: Duration,
    cancellation: &CancellationToken,
) -> Result<PinnedAiRuntime, RuntimeStartupError> {
    // Refused before any key material exists, so a cancelled start does not
    // create a file it is only going to delete again.
    if cancellation.is_cancelled() {
        return Err(RuntimeStartupError::Cancelled);
    }
    let (key, key_file) = create_key_material(&plan, key_file_root)?;
    launch(
        plan,
        process,
        key,
        key_file,
        readiness_deadline,
        cancellation,
    )
    .await
}

/// Build the Windows process adapter for a reviewed plan.
///
/// Exposed because a caller of [`start_planned_ai_runtime`] on Windows has to
/// build this itself, and because the mapping from the adapter's typed refusal
/// to [`ProcessRefusal`] is part of this module's contract.
///
/// The executable and the model resolve against `installed_root`; the key file
/// resolves against `key_file_root`, which is normally a different, per-user
/// writable directory. See [`resolve_installed_path`] for why the two roots are
/// not the same.
#[cfg(windows)]
pub fn windows_process_for_plan(
    plan: &RuntimeLaunchPlan,
    installed_root: &Path,
    key_file_root: &Path,
) -> Result<crate::runtime_process_windows::WindowsRuntimeProcess, ProcessRefusal> {
    use crate::runtime_process_windows::WindowsRuntimeProcess;
    WindowsRuntimeProcess::from_plan(plan, installed_root, key_file_root)
        .map_err(ProcessRefusal::from)
}

/// Start the pinned local AI runtime from the reviewed manifest and staging
/// receipt, and return only once it is answering.
///
/// This is the broker's startup path, not a key-input path. It awaits a process
/// start and a readiness poll, so the caller must not block its pipe listener on
/// it; see "Requirement on the caller" in the module documentation.
///
/// `port` is explicit. Use [`reserve_loopback_port`] to choose one; the caller
/// owns that decision because the port ends up in a command line and in the
/// backend's base URL. `readiness_deadline` is explicit for the same reason.
///
/// `key_file_root` must be a directory the current user can create files in.
/// It is deliberately not `installed_root`: a default install lives under
/// `C:\Program Files`, which a non-elevated process cannot write, so writing the
/// key there would leave the AI path permanently off. Point it at a per-user
/// directory instead. The path still has to be ASCII, because the pinned build
/// is refused rather than started when its command line is not.
///
/// Every failure is a typed [`RuntimeStartupError`], and each one leaves nothing
/// behind: the key file is removed and the supervisor is released as the error
/// propagates, so a caller that keeps the Mozc baseline is not left with a
/// secret on disk or an unreaped model process.
#[cfg(windows)]
pub async fn start_pinned_ai_runtime(
    manifest_json: &[u8],
    receipt_json: &[u8],
    installed_root: &Path,
    key_file_root: &Path,
    port: u16,
    readiness_deadline: Duration,
    cancellation: &CancellationToken,
) -> Result<PinnedAiRuntime, RuntimeStartupError> {
    use crate::local_runtime::{RuntimeLaunchOptions, build_runtime_launch_plan};

    if cancellation.is_cancelled() {
        return Err(RuntimeStartupError::Cancelled);
    }
    if port == 0 {
        return Err(RuntimeStartupError::PortRejected);
    }
    let token_reference = random_token_reference()?;
    let plan = build_runtime_launch_plan(
        manifest_json,
        receipt_json,
        RuntimeLaunchOptions::new(port, RUNTIME_API_KEY_FILE_RELATIVE, token_reference),
    )
    .map_err(|_| RuntimeStartupError::LaunchPlanInvalid)?;

    let (key, key_file) = create_key_material(&plan, key_file_root)?;
    let process = windows_process_for_plan(&plan, installed_root, key_file_root)?;
    launch(
        plan,
        Arc::new(process),
        key,
        key_file,
        readiness_deadline,
        cancellation,
    )
    .await
}

/// Generate the key and write its file, in that order.
///
/// The plan is built first, so an invalid plan never produces a key file, and
/// the key is generated before the file is created, so a failed write leaves no
/// key value in memory longer than the call.
///
/// The file goes under `key_file_root`, which is a writable directory rather
/// than the install root; see [`start_pinned_ai_runtime`].
fn create_key_material(
    plan: &RuntimeLaunchPlan,
    key_file_root: &Path,
) -> Result<(RuntimeApiKey, RuntimeApiKeyFile), RuntimeStartupError> {
    let path = resolve_installed_path(key_file_root, plan.api_key_file_path.as_str());
    let key = RuntimeApiKey::generate()?;
    let key_file = RuntimeApiKeyFile::create(&path, &key)?;
    Ok((key, key_file))
}

/// Attach the child, wait for readiness, and hand back the owned handle.
async fn launch(
    plan: RuntimeLaunchPlan,
    process: Arc<dyn RuntimeProcess>,
    key: RuntimeApiKey,
    key_file: RuntimeApiKeyFile,
    readiness_deadline: Duration,
    cancellation: &CancellationToken,
) -> Result<PinnedAiRuntime, RuntimeStartupError> {
    if cancellation.is_cancelled() {
        return Err(RuntimeStartupError::Cancelled);
    }
    // The probe validates the deadline too, but only after a process has been
    // started and a secret written. Checking it here means an unusable deadline
    // costs nothing.
    if readiness_deadline.is_zero() || readiness_deadline > MAX_READINESS_DEADLINE {
        return Err(RuntimeStartupError::ReadinessProbe(
            RuntimeProbeError::InvalidDeadline,
        ));
    }
    let supervisor = RuntimeSupervisor::new(
        process,
        Arc::new(TokioRuntimeClock),
        RuntimeSupervisorConfig::default(),
    )
    .map_err(|_| RuntimeStartupError::SupervisorConfigInvalid)?;

    // From here on, an early return drops `supervisor`, whose `Drop` signals the
    // monitor to force-stop the child, and drops `key_file`, which removes the
    // secret. No failure path below needs its own cleanup.
    supervisor
        .start()
        .await
        .map_err(|_| RuntimeStartupError::SupervisorStartFailed)?;
    if cancellation.is_cancelled() {
        return Err(RuntimeStartupError::Cancelled);
    }

    // `start` returning means a child handle is attached, not that the model is
    // answering, and not that the peer answering is our child. Only a `200` from
    // `/health` on a connection whose server end the operating system attributes
    // to this child means the slow path is worth enabling; anything else is a
    // typed error and a clean teardown. See the module documentation for why the
    // ownership half of that is not optional.
    let ownership = RuntimeOwnership {
        supervisor: Arc::clone(&supervisor),
        port: plan.port,
    };
    probe_owned_runtime_readiness(plan.port, readiness_deadline, cancellation, &ownership)
        .await
        .map_err(RuntimeStartupError::from)?;

    let base_url = format!("http://{RUNTIME_LOOPBACK_HOST}:{}", plan.port);
    Ok(PinnedAiRuntime {
        supervisor: Some(supervisor),
        key,
        key_file: Some(key_file),
        base_url,
        port: plan.port,
    })
}

/// Resolve an installed-relative value against the install root, with native
/// separators.
///
/// The reviewed plan stores installed paths with forward slashes so the manifest
/// and the staging receipt stay portable. Windows tolerates a forward slash
/// inside a path, so the file is still found, but the resulting path is not
/// equal to the same path as the operating system reports it, and an equality
/// check against a running process would fail silently. The process adapter
/// normalizes for exactly that reason, and this module must agree with it: the
/// key file is written here and looked for there, so both must resolve the same
/// relative value to the same file.
fn resolve_installed_path(installed_root: &Path, relative: &str) -> PathBuf {
    let joined = installed_root.join(relative);
    let mut native = PathBuf::new();
    for component in joined.components() {
        match component {
            // Keep the drive or UNC prefix exactly as the root expressed it.
            Component::Prefix(prefix) => native.push(prefix.as_os_str()),
            Component::RootDir => native.push(std::path::MAIN_SEPARATOR_STR),
            // A reviewed relative path contains no `.`; dropping it keeps the
            // native form identical to what the operating system reports.
            Component::CurDir => {}
            Component::ParentDir => native.push(Component::ParentDir.as_os_str()),
            Component::Normal(part) => native.push(part),
        }
    }
    native
}

/// An opaque, bounded, per-process reference for the key-file slot.
///
/// It is not a secret and never reaches a process command line; it exists so two
/// concurrent brokers in one install root do not share a key-file slot. It is
/// generated from the same CSPRNG as the key but independently, so it leaks
/// nothing about the key.
fn random_token_reference() -> Result<String, RuntimeStartupError> {
    let mut bytes = [0_u8; 8];
    fill_random(&mut bytes)?;
    let mut reference = String::from("kanai-");
    for byte in bytes {
        use std::fmt::Write as _;
        // Writing into a `String` cannot fail.
        let _ = write!(reference, "{byte:02x}");
    }
    Ok(reference)
}

#[cfg(windows)]
fn fill_random(bytes: &mut [u8]) -> Result<(), RuntimeStartupError> {
    use windows_sys::Win32::Security::Cryptography::{
        BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
    };

    let Ok(length) = u32::try_from(bytes.len()) else {
        return Err(RuntimeStartupError::RandomSourceUnavailable);
    };
    // SAFETY: `BCryptGenRandom` with `BCRYPT_USE_SYSTEM_PREFERRED_RNG` ignores
    // the algorithm handle and documents a null handle as valid with that flag,
    // so no algorithm has to be opened. `bytes` is a live, exclusively owned
    // buffer of exactly `length` bytes, which is what the call writes.
    let status = unsafe {
        BCryptGenRandom(
            std::ptr::null_mut(),
            bytes.as_mut_ptr(),
            length,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    // `NTSTATUS` is a signed status code where any non-negative value is
    // success; `BCRYPT_SUCCESS` is not a constant the crate exposes.
    if status >= 0 {
        Ok(())
    } else {
        Err(RuntimeStartupError::RandomSourceUnavailable)
    }
}

#[cfg(not(windows))]
fn fill_random(_bytes: &mut [u8]) -> Result<(), RuntimeStartupError> {
    // No cryptographically secure random source is reachable from this crate's
    // current dependency set on this platform. Returning a weaker value would be
    // a silent downgrade of a secret, so this reports the failure instead.
    Err(RuntimeStartupError::RandomSourceUnavailable)
}

/// A Win32 handle that is closed when this value is dropped.
#[cfg(windows)]
struct OwnedWin32Handle(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl Drop for OwnedWin32Handle {
    fn drop(&mut self) {
        // SAFETY: the handle was checked for validity before it was wrapped, it
        // is owned exclusively by this value, and `Drop` needs `&mut self`, so
        // no other call can be using it concurrently.
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

/// A Win32-allocated buffer released with `LocalFree`.
#[cfg(windows)]
struct LocalAllocation(*mut std::ffi::c_void);

#[cfg(windows)]
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        // SAFETY: the pointer came from a Win32 allocator
        // (`ConvertStringSecurityDescriptorToSecurityDescriptorW` or
        // `ConvertSidToStringSidW`), is owned exclusively by this value, and is
        // released exactly once.
        unsafe { windows_sys::Win32::Foundation::LocalFree(self.0) };
    }
}

/// The length of a NUL-terminated UTF-16 string, excluding the terminator.
///
/// # Safety
///
/// `text` must point at a NUL-terminated UTF-16 string that stays valid and
/// unmodified for the duration of the call.
#[cfg(windows)]
unsafe fn wide_string_length(text: *const u16) -> usize {
    let mut length = 0_usize;
    // SAFETY: the caller guarantees `text` is a NUL-terminated UTF-16 string that
    // stays valid and unmodified, so reading forward one unit at a time until the
    // terminator stays inside it.
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    length
}

/// The SID of the account this process runs as, in `S-1-...` string form.
///
/// Naming the account explicitly is what makes the DACL precise: there is no
/// "current user" token in SDDL, and an owner-rights alias would depend on how
/// the file's owner was assigned.
#[cfg(windows)]
fn current_user_sid_string() -> Result<String, RuntimeStartupError> {
    use std::ffi::c_void;

    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: `token` is a live out-parameter of the type the call writes, and
    // the pseudo-handle `GetCurrentProcess` returns must not be closed.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    let token = OwnedWin32Handle(token);

    // A token user is a fixed structure immediately followed by the
    // variable-length SID *inside the same buffer*, so the size the operating
    // system needs is larger than `size_of::<TOKEN_USER>()`. Asking with no buffer
    // is the supported way to learn it: the call fails and reports what it needs.
    // Passing the structure size instead is a classic way to end up with a null
    // SID and a security descriptor that grants nothing.
    let mut required = 0_u32;
    // SAFETY: a null buffer with a zero length is the documented way to request
    // the size, and `required` is a live out-parameter. The call is expected to
    // fail, so its return value carries no information.
    let _ =
        unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut required) };
    let structure_bytes = u32::try_from(std::mem::size_of::<TOKEN_USER>()).unwrap_or(u32::MAX);
    if required < structure_bytes {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    // A `u64` element keeps the alignment the structure requires, whatever size
    // the operating system reports; a byte buffer would not, and reading it as a
    // `TOKEN_USER` would be unsound.
    let Ok(size) = usize::try_from(required) else {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    };
    let mut buffer = vec![0_u64; size.div_ceil(std::mem::size_of::<u64>())];
    let mut returned = 0_u32;
    // SAFETY: `buffer` is a live, exclusively owned allocation of at least
    // `required` bytes, the call is told that length, and the return value is
    // checked before anything is read back.
    let ok = unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr().cast::<std::ffi::c_void>(),
            required,
            &mut returned,
        )
    };
    if ok == 0 || returned < structure_bytes {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    // SAFETY: the call succeeded and reported at least a whole `TOKEN_USER`, and
    // the buffer is `u64`-aligned, which is the alignment `TOKEN_USER` requires.
    // The `User.Sid` pointer inside it points into this same buffer or into the
    // still-open token, so it is valid for the conversion below.
    let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    let mut sid: *mut u16 = std::ptr::null_mut();
    // SAFETY: `sid` is a live out-parameter, and the SID belongs to the token
    // that is still open, so the call may read it.
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut sid) } == 0 || sid.is_null() {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    let sid = LocalAllocation(sid.cast::<c_void>());

    // SAFETY: `sid` owns the NUL-terminated wide string the call allocated, and
    // `sid` is alive until the end of this function.
    let units = unsafe {
        let text = sid.0.cast::<u16>();
        std::slice::from_raw_parts(text, wide_string_length(text))
    };
    // A SID string is ASCII. If it somehow were not valid UTF-16 the lossy
    // conversion would produce an SDDL the next call rejects, which is a typed
    // error rather than a silently weakened DACL.
    Ok(String::from_utf16_lossy(units))
}

/// Create a file only the calling account can read, and write `secret` into it.
///
/// The access control list is supplied at creation, so there is no window in
/// which the file exists with an inherited, possibly permissive, DACL.
#[cfg(windows)]
/// Create every missing directory in `root` with the same restrictive access
/// control list as the key file.
///
/// The directories get a protected DACL naming only the current user, so the
/// key file is not briefly readable through an inherited `Users` ACE while the
/// chain is being created. An existing directory is left exactly as it is: the
/// caller owns the root, and rewriting its permissions would be a surprise.
///
/// Only ancestors of the key file are created, and only from a relative plan
/// path that has already been rejected if it contains `..`, an absolute prefix,
/// or a reserved character.
#[cfg(windows)]
fn create_private_directories(root: &Path) -> Result<(), RuntimeStartupError> {
    use std::os::windows::ffi::OsStrExt;

    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
    use windows_sys::Win32::Storage::FileSystem::CreateDirectoryW;

    let sddl = format!("D:P(A;;FA;;;{})", current_user_sid_string()?);
    let mut sddl_wide: Vec<u16> = sddl.encode_utf16().collect();
    sddl_wide.push(0);
    let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: `sddl_wide` is a live NUL-terminated wide string and `descriptor` is
    // a live out-parameter that `LocalAllocation` releases on every path out.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_wide.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            std::ptr::null_mut(),
        )
    } == 0
        || descriptor.is_null()
    {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    let descriptor = LocalAllocation(descriptor.cast::<std::ffi::c_void>());

    let attributes = SECURITY_ATTRIBUTES {
        // The structure is three fields wide, so this does not truncate in
        // practice; a `try_from` fallback could only pass a wrong length, which
        // would make the call fail for the wrong reason.
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };

    // Ancestors run leaf-first; a directory cannot be created before its parent,
    // so the chain is walked root-first.
    let mut chain: Vec<&Path> = root.ancestors().collect();
    chain.reverse();
    for directory in chain {
        if directory.as_os_str().is_empty() || directory.is_dir() {
            continue;
        }
        let mut wide: Vec<u16> = directory.as_os_str().encode_wide().collect();
        wide.push(0);
        // SAFETY: `wide` is a live NUL-terminated wide string, and `attributes`
        // and its descriptor outlive the call. The protected DACL is what keeps
        // the key file from being readable through an inherited `Users` ACE.
        // SAFETY: `wide` is a live NUL-terminated wide string, and `attributes`
        // and its descriptor outlive the call. The protected DACL is what keeps
        // the key file from being readable through an inherited `Users` ACE.
        let created = unsafe { CreateDirectoryW(wide.as_ptr(), &attributes) };

        if created == 0 && !directory.is_dir() {
            // A parallel start can win the race, and the goal is "the directory
            // exists with a protected DACL", so a re-check is not a failure.
            // Any other error is not something this function can repair.
            return Err(RuntimeStartupError::KeyFileCreateFailed);
        }
    }
    Ok(())
}

fn create_restricted_file(
    path: &Path,
    secret: &[u8],
) -> Result<RuntimeApiKeyFile, RuntimeStartupError> {
    use std::os::windows::ffi::OsStrExt;

    use windows_sys::Win32::Foundation::{GENERIC_WRITE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
    use windows_sys::Win32::Storage::FileSystem::{
        CREATE_NEW, CreateFileW, FILE_ATTRIBUTE_TEMPORARY, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_SHARE_NONE, WriteFile,
    };

    // `D:` selects the DACL and `P` protects it, so no ACE is inherited from the
    // parent directory. Without `P` this file would receive the directory's
    // inherited `Users` read ACE, which is exactly the exposure being
    // prevented. The single ACE names one principal, so no group, `Everyone`, or
    // `Authenticated Users` can read the key.
    let sddl = format!("D:P(A;;FA;;;{})", current_user_sid_string()?);
    // The API takes wide characters, and `String::as_ptr` would hand it bytes.

    let mut sddl_wide: Vec<u16> = sddl.encode_utf16().collect();
    sddl_wide.push(0);
    let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: `sddl_wide` is a live NUL-terminated wide string and `descriptor` is a
    // live out-parameter. The returned descriptor is Win32-allocated, and
    // `descriptor` below releases it on every path out of this function.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_wide.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            std::ptr::null_mut(),
        )
    } == 0
        || descriptor.is_null()
    {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    let descriptor = LocalAllocation(descriptor.cast::<std::ffi::c_void>());

    let attributes = SECURITY_ATTRIBUTES {
        // The structure is three fields wide, so this does not truncate in
        // practice; a `try_from` fallback could only pass a wrong length, which
        // would make the call fail for the wrong reason.
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };

    let mut wide_path: Vec<u16> = path.as_os_str().encode_wide().collect();
    wide_path.push(0);

    // Never open an existing file: CREATE_ALWAYS would preserve its old ACL
    // and could overwrite another runtime's key. The caller supplies a unique
    // private directory; collisions fail without modifying or deleting it.
    // SAFETY: `wide_path` is a live NUL-terminated wide string, `attributes` and
    // its descriptor outlive the call, and the returned handle is checked
    // against both documented failure values before it is wrapped.
    let handle = unsafe {
        CreateFileW(
            wide_path.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_NONE,
            &attributes,
            CREATE_NEW,
            FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE || handle.is_null() {
        return Err(RuntimeStartupError::KeyFileCreateFailed);
    }
    let handle = OwnedWin32Handle(handle);

    // The key file must not outlive a failed start, so the guard that removes it
    // is created before the first write: every early return below drops it.
    let pending = RuntimeApiKeyFile {
        path: Some(path.to_path_buf()),
    };
    let length =
        u32::try_from(secret.len()).map_err(|_| RuntimeStartupError::KeyFileCreateFailed)?;
    let mut written_total = 0_u32;
    while written_total < length {
        let offset =
            usize::try_from(written_total).map_err(|_| RuntimeStartupError::KeyFileCreateFailed)?;
        let remaining = secret
            .get(offset..)
            .ok_or(RuntimeStartupError::KeyFileCreateFailed)?;
        let mut written = 0_u32;
        // SAFETY: `remaining` is inside `secret`, its length is the difference
        // the call is told about, and the byte-count out-parameter is live.
        let ok = unsafe {
            WriteFile(
                handle.0,
                remaining.as_ptr(),
                length - written_total,
                &mut written,
                std::ptr::null_mut(),
            )
        };
        // A zero-byte write would otherwise spin forever.
        if ok == 0 || written == 0 {
            return Err(RuntimeStartupError::KeyFileCreateFailed);
        }
        written_total = written_total
            .checked_add(written)
            .ok_or(RuntimeStartupError::KeyFileCreateFailed)?;
    }
    // The bytes stay in the operating system cache and are deliberately never
    // flushed to disk: a child process reads them through that same cache, so
    // durability buys nothing, and a secret is better off not reaching a disk.
    Ok(pending)
}

/// Create a private file and write `secret` into it on non-Windows platforms.
///
/// The pinned runtime is a Windows build, so this exists to keep the composition
/// chain compiling elsewhere. `0o600` is the equivalent of the DACL above for a
/// POSIX host; that path is not exercised by this repository's tests and is not
/// claimed to be verified.
#[cfg(not(windows))]
fn create_restricted_file(
    path: &Path,
    secret: &[u8],
) -> Result<RuntimeApiKeyFile, RuntimeStartupError> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| RuntimeStartupError::KeyFileCreateFailed)?;
    let pending = RuntimeApiKeyFile {
        path: Some(path.to_path_buf()),
    };
    file.write_all(secret)
        .map_err(|_| RuntimeStartupError::KeyFileCreateFailed)?;
    Ok(pending)
}
