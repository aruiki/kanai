//! Windows process adapter for the bounded AI runtime supervisor.
//!
//! This module starts the pinned `llama-server` as a real child process so the
//! supervisor can own its lifecycle. It is deliberately narrow:
//!
//! * the child is created inside a Job Object with
//!   `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so the runtime is killed with the
//!   broker instead of being orphaned once the job owns it (see "Known
//!   limitation" for the window before that assignment completes);
//! * the command line comes from a reviewed [`RuntimeLaunchPlan`] and contains
//!   only the path of a per-process key file, never the key value;
//! * the two installed-relative values are substituted by position, never by
//!   matching argument text, because
//!   [`RuntimeLaunchPlan::api_key_file_path`] is caller-supplied and can
//!   collide with a literal in the same vector;
//! * stdout and stderr are discarded rather than parsed, so no prompt,
//!   candidate, or token can reach a log; and
//! * the adapter never opens a socket and never loads the model itself.
//!
//! A started child is not evidence that the AI path works. Nothing here waits
//! for a health response, and callers must keep the Mozc fallback whenever the
//! model is not answering.
//!
//! # Non-ASCII command line
//!
//! The resolved command line must be ASCII. In one controlled run of the pinned
//! llama.cpp b11146 build (revision
//! `7fe450e19305b828c199d602c23a8337aaa1f03b`) from a Japanese staging root the
//! runtime never reached a serving state, while the same bytes loaded and
//! answered a request through an ASCII path. That is a single observation of one
//! build on one machine, not a measured property of llama.cpp in general, and
//! this module does not claim it is one. Rather than start a child that may not
//! answer, [`WindowsRuntimeProcess::from_plan`] refuses a non-ASCII command line
//! with [`WindowsProcessError::NonAsciiCommandPath`]. The default install root
//! is `Program Files`, so a default install satisfies this; a custom install
//! directory under a localized profile needs the future ASCII-safe path
//! projection before the AI slow path can run there.
//!
//! # Known limitation
//!
//! There is a window between process creation and
//! `AssignProcessToJobObject` in which the child is already running but is not
//! yet owned by the job. A broker death that does not unwind - `abort`, an
//! external `TerminateProcess`, or power loss - can therefore leave the runtime
//! alive with nobody left to terminate it. This is not fixed here.
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` only binds the child once the assignment
//! has succeeded. Closing the window requires either
//! `PROC_THREAD_ATTRIBUTE_JOB_LIST` on the `CreateProcessW` call, or creating
//! the child suspended with `CREATE_SUSPENDED`, assigning the job, and then
//! resuming its main thread. Both need a direct `CreateProcessW` instead of
//! `tokio::process::Command`, so both are out of scope for this adapter.

use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use async_trait::async_trait;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::local_runtime::RuntimeLaunchPlan;
use crate::runtime_supervisor::{RuntimeChild, RuntimeProcess, RuntimeProcessError};

/// The reviewed flag whose value is the installed-relative model path.
const MODEL_FLAG: &str = "--model";
/// The reviewed flag whose value is the installed-relative key-file path.
const KEY_FILE_FLAG: &str = "--api-key-file";

/// Failures that are safe to report. They never carry command output, a token,
/// or caller-supplied model content.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum WindowsProcessError {
    #[error("AI runtime executable is missing or not a file")]
    MissingExecutable,
    #[error("AI runtime model weights are missing or not a file")]
    MissingModel,
    #[error("AI runtime API-key file is missing or not a file")]
    MissingKeyFile,
    /// The resolved command line is not ASCII, or is not valid Unicode.
    ///
    /// One message intentionally covers two distinct operator problems: a path
    /// that contains non-ASCII characters, and a path that is not valid Unicode
    /// at all (a lone surrogate surviving from an ill-formed command line).
    /// Both are fixed by the same operator action - stage the runtime under an
    /// ASCII path - and neither can be reported without naming the path, which
    /// this type must not do, so they share one content-free message instead of
    /// two variants that differ only in a detail the operator cannot act on
    /// separately.
    #[error("AI runtime command line resolves to a non-ASCII path")]
    NonAsciiCommandPath,
    /// The reviewed argument vector did not resolve to the shape this adapter
    /// requires, so no child was started.
    ///
    /// The message is fixed on purpose: a mismatch can be caused by a
    /// caller-chosen key-file path, and the reported text must not echo it.
    #[error("AI runtime argument plan does not match the reviewed launch shape")]
    ArgumentPlanMismatch,
}

/// An owned Win32 handle that is closed on drop.
struct OwnedHandle(windows_sys::Win32::Foundation::HANDLE);

impl OwnedHandle {
    fn new(handle: windows_sys::Win32::Foundation::HANDLE) -> Option<Self> {
        (!handle.is_null()).then_some(Self(handle))
    }

    /// Terminate the job, which also kills anything the runtime spawned.
    fn terminate(&self) -> Result<(), RuntimeProcessError> {
        use windows_sys::Win32::System::JobObjects::TerminateJobObject;
        if unsafe { TerminateJobObject(self.0, 1) } == 0 {
            Err(RuntimeProcessError::Rejected)
        } else {
            Ok(())
        }
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

// `request_stop` and `monitor_child` run on different tasks, so `terminate`
// can be called concurrently; the handle is not only ever read afterwards, and
// no mutex serializes those calls. The impls are still sound because the stored
// handle value is immutable: every method takes `&self` and only reads it, so
// concurrent callers pass the same value and no shared mutable state exists.
// `CloseHandle` is reachable only from `Drop`, which needs `&mut self`; the
// handle is owned by one `WindowsRuntimeChild`, so a `&self` borrow cannot
// coexist with the drop and the handle cannot be closed while a terminate call
// is in flight. `HANDLE` is a raw pointer, so the impls are required rather
// than automatic.
unsafe impl Send for OwnedHandle {}
unsafe impl Sync for OwnedHandle {}

/// Which installed-relative value the next element of the argument vector
/// carries. The role comes from position, never from the element's text.
#[derive(Clone, Copy, PartialEq, Eq)]
enum ArgumentRole {
    Model,
    KeyFile,
}

impl ArgumentRole {
    fn for_flag(flag: &str) -> Option<Self> {
        match flag {
            MODEL_FLAG => Some(Self::Model),
            KEY_FILE_FLAG => Some(Self::KeyFile),
            _ => None,
        }
    }
}

/// Substitute the two installed-relative values into the reviewed argument
/// vector, by position rather than by value.
///
/// [`RuntimeLaunchPlan::api_key_file_path`] is caller-supplied and validated
/// only as a relative path, so a caller can choose a value that equals a
/// literal in the same vector. Rewriting by text would then hit the wrong
/// element: `api_key_file = "127.0.0.1"` would rewrite the `--host` literal as
/// well and bind the runtime to `<root>\127.0.0.1`,
/// `api_key_file = "--api-key-file"` would rewrite the flag itself and leave the
/// child with no `--api-key-file` at all - an unauthenticated loopback HTTP
/// server - and `api_key_file = "none"` would rewrite the `--device` value. So
/// the role of an element is taken from the flag that precedes it, every other
/// element passes through unchanged, and the result is checked against explicit
/// post-conditions before any child can exist.
fn resolve_arguments(
    declared: &[String],
    model: &Path,
    key_file: &Path,
) -> Result<Vec<OsString>, WindowsProcessError> {
    let mut arguments: Vec<OsString> = Vec::with_capacity(declared.len());
    let mut pending: Option<ArgumentRole> = None;
    for element in declared {
        if let Some(role) = pending.take() {
            let resolved = match role {
                ArgumentRole::Model => model,
                ArgumentRole::KeyFile => key_file,
            };
            arguments.push(resolved.as_os_str().to_os_string());
            continue;
        }
        let flag = element.as_str();
        if let Some(role) = ArgumentRole::for_flag(flag) {
            pending = Some(role);
        }
        arguments.push(OsString::from(flag));
    }
    // A flag with no element after it can never be given a value.
    if pending.is_some() {
        return Err(WindowsProcessError::ArgumentPlanMismatch);
    }

    // Post-conditions. Each resolved value must appear exactly once, so a
    // substitution can neither be dropped nor duplicated, and both flags must
    // survive, so the child can never be launched without one of them.
    if occurrences(&arguments, model.as_os_str()) != 1
        || occurrences(&arguments, key_file.as_os_str()) != 1
        || occurrences(&arguments, OsStr::new(MODEL_FLAG)) != 1
        || occurrences(&arguments, OsStr::new(KEY_FILE_FLAG)) != 1
    {
        return Err(WindowsProcessError::ArgumentPlanMismatch);
    }
    Ok(arguments)
}

/// Count the elements of `arguments` that are exactly `value`.
fn occurrences(arguments: &[OsString], value: &OsStr) -> usize {
    arguments
        .iter()
        .filter(|argument| argument.as_os_str() == value)
        .count()
}

/// Resolve an installed-relative value against the install root, using native
/// separators.
///
/// The reviewed plan deliberately stores installed paths with forward slashes
/// so the manifest and the staging receipt stay portable and platform
/// independent. Windows tolerates a forward slash inside a path, so the process
/// still starts, but the resulting path is not equal to the same path as the
/// operating system reports it: a `C:\app/runtime/llama-server.exe` image
/// compares unequal to `C:\app\runtime\llama-server.exe`. Any equality check
/// against a running process therefore fails silently, so the separator has to
/// be normalised here rather than at each comparison.
fn installed_under(installed_root: &Path, relative: &str) -> PathBuf {
    use std::path::Component;
    let joined = installed_root.join(relative);
    let mut native = PathBuf::new();
    for component in joined.components() {
        match component {
            // Keep the drive or UNC prefix exactly as the root expressed it.
            Component::Prefix(prefix) => native.push(prefix.as_os_str()),
            Component::RootDir => native.push(std::path::MAIN_SEPARATOR_STR),
            // A reviewed relative path never contains `.`; dropping it keeps
            // the native form identical to what the OS reports.
            Component::CurDir => {}
            Component::ParentDir => native.push(Component::ParentDir.as_os_str()),
            Component::Normal(part) => native.push(part),
        }
    }
    native
}

/// Starts the pinned runtime described by a reviewed launch plan.
pub struct WindowsRuntimeProcess {
    executable: PathBuf,
    working_directory: PathBuf,
    /// The resolved API-key path, kept so every start can re-validate it. It is
    /// never reported by `Debug`; see the impl above.
    key_file: PathBuf,
    arguments: Vec<OsString>,
}

impl fmt::Debug for WindowsRuntimeProcess {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // A derived `Debug` would print absolute paths, which embed the Windows
        // account name and the install layout. Only the executable's file name
        // and the argument count are reported, and those are enough to tell two
        // adapters apart in a log line.
        let executable = self
            .executable
            .file_name()
            .and_then(OsStr::to_str)
            .unwrap_or("<unprintable>");
        formatter
            .debug_struct("WindowsRuntimeProcess")
            .field("executable", &executable)
            .field("argument_count", &self.arguments.len())
            .finish()
    }
}

impl WindowsRuntimeProcess {
    /// Build a process factory from a validated launch plan.
    ///
    /// `installed_root` is where the executable and the model live: a
    /// `C:\Program Files` install, which is read-only for a non-elevated
    /// process and therefore the right place for reviewed, immutable bytes.
    ///
    /// `key_file_root` is a separate, writable directory, and the plan's
    /// key-file path resolves against *it* rather than against the install root.
    /// A per-process secret cannot live under `C:\Program Files`: a default
    /// install would make the file impossible to create, which silently leaves
    /// the AI path off for every non-elevated user. Both roots still produce a
    /// bounded relative path from the reviewed plan, so neither can introduce a
    /// traversal, an absolute path, or an unreviewed location.
    ///
    /// Every other argument is a literal flag or number from the reviewed plan,
    /// so nothing else caller-supplied reaches the command line. The two path
    /// values are substituted by position, not by matching their text against
    /// the vector, because the key-file path is caller-supplied and can equal
    /// one of the literals.
    ///
    /// The executable, the model, and the key file must already exist; only
    /// their metadata is read here, never their contents. Refusing before a
    /// child exists is what keeps a missing key file from becoming a runtime
    /// that binds loopback without authentication and reports a successful
    /// start. The assumption that the pinned runtime would refuse such a start
    /// is not relied on here.
    ///
    /// This does not create the key file: the caller owns the secret, writes it
    /// to a protected location, and only then hands the plan here.
    pub fn from_plan(
        plan: &RuntimeLaunchPlan,
        installed_root: &Path,
        key_file_root: &Path,
    ) -> Result<Self, WindowsProcessError> {
        let server = installed_under(installed_root, plan.server_path.as_str());
        if !server.is_file() {
            return Err(WindowsProcessError::MissingExecutable);
        }
        let model = installed_under(installed_root, plan.model_path.as_str());
        if !model.is_file() {
            return Err(WindowsProcessError::MissingModel);
        }
        let key_file = installed_under(key_file_root, plan.api_key_file_path.as_str());
        if !key_file.is_file() {
            return Err(WindowsProcessError::MissingKeyFile);
        }

        let declared = plan.launch_arguments();
        let arguments = resolve_arguments(&declared, &model, &key_file)?;

        // See "Non-ASCII command line": a non-ASCII command line is a silent AI
        // failure, so refuse it before a child exists.
        let mut is_ascii = server.to_str().is_some_and(str::is_ascii);
        is_ascii &= arguments
            .iter()
            .all(|argument| argument.to_str().is_some_and(str::is_ascii));
        if !is_ascii {
            return Err(WindowsProcessError::NonAsciiCommandPath);
        }

        Ok(Self {
            working_directory: server
                .parent()
                .map_or_else(|| installed_root.to_path_buf(), Path::to_path_buf),
            executable: server,
            key_file,
            arguments,
        })
    }

    /// The resolved executable path.
    pub fn executable(&self) -> &Path {
        &self.executable
    }

    /// The resolved API-key path, for a caller that wants to re-check it.
    ///
    /// It is an installed-relative value resolved against the key root, so it is
    /// a per-user path rather than a payload path; `Debug` still does not print
    /// it, because a path under a user profile embeds the account name.
    pub fn key_file(&self) -> &Path {
        &self.key_file
    }

    /// A deterministic rendering of the command line this adapter will use.
    ///
    /// It contains installed paths and literal flags but never the API-key
    /// value or the opaque token reference, so it is safe to log. The test
    /// suite asserts against this instead of re-deriving the plan's own
    /// argument list, so it exercises the adapter's own resolution.
    #[must_use]
    pub fn redacted_command_line(&self) -> String {
        let mut rendered = self.executable.display().to_string();
        for argument in &self.arguments {
            rendered.push(' ');
            rendered.push_str(&argument.to_string_lossy());
        }
        rendered
    }

    /// The arguments this adapter will pass, after substitution.
    ///
    /// This is the adapter's own resolution, not the plan's declared vector, and
    /// a caller that has to inspect the result element by element - because a
    /// joined string cannot distinguish one argument from a path containing a
    /// space - has to look here rather than re-derive the plan.
    #[must_use]
    pub fn resolved_arguments(&self) -> &[OsString] {
        &self.arguments
    }
}

/// One owned child process plus the job object that guarantees its death.
struct WindowsRuntimeChild {
    child: Mutex<Child>,
    job: OwnedHandle,
    // Separate owned handle permits a liveness check while wait() holds the
    // async child mutex. Holding it also prevents PID reuse after termination.
    process: OwnedHandle,
    pid: u32,
}

#[async_trait]
impl RuntimeProcess for WindowsRuntimeProcess {
    async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError> {
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        };
        use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

        // Re-validate the key file on every start, not only where the adapter was
        // built. The supervisor may start a replacement child long after
        // `from_plan` ran, and the broker removes the key file while tearing the
        // runtime down; a start that found it missing would launch a loopback
        // model server that has no key to authenticate against, which is the one
        // outcome every other check here exists to prevent. This runs before the
        // job object is created, so a refusal leaves nothing behind.
        if !self.key_file.is_file() {
            return Err(RuntimeProcessError::Unavailable);
        }

        // Create the job before the child so the only failure ordering is
        // "job unavailable" (nothing has run yet) rather than the reverse.
        let job = OwnedHandle::new(unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) })
            .ok_or(RuntimeProcessError::Unavailable)?;
        let mut limits = unsafe { std::mem::zeroed::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let limits_ok = unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&limits).cast(),
                // A plain cast is exact: the structure is a few dozen bytes on
                // every target this crate supports. `try_from(..)` with an
                // `unwrap_or(u32::MAX)` fallback could only be reached if the
                // size did not fit, and it would have passed a bogus length
                // instead of failing, so the call would fail for the wrong
                // reason and the reported error would mislead the operator.
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        if limits_ok == 0 {
            return Err(RuntimeProcessError::Unavailable);
        }

        // `kill_on_drop` means every early return below still terminates the
        // child, so a failed start can never leave a model process behind.
        let child = Command::new(self.executable.as_os_str())
            .args(&self.arguments)
            .current_dir(&self.working_directory)
            // `CREATE_NO_WINDOW` keeps the child from sharing a console with
            // the broker. This is determinism, not a leak fix: all three
            // standard streams are already `Stdio::null()`, so nothing the
            // runtime prints can reach a console; without the flag a
            // console-hosted broker would hand the child a console of its own.
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| RuntimeProcessError::Unavailable)?;

        // The child is already running at this point, so a refusal here is
        // reported as an unavailable start and the child is killed on drop.
        // Nested job objects need Windows 8 or later, and the assignment also
        // fails when the broker's own job carries a UI restriction such as
        // `JOB_OBJECT_UILIMIT_HANDLES`, so a refusal here means the broker runs
        // in a job that forbids the assignment rather than a transient
        // condition. The `Unavailable` contract of [`RuntimeProcess`] is fixed
        // to three content-free variants, so no stage-specific cause is
        // reported and no command output can leak through it.
        if unsafe { AssignProcessToJobObject(job.0, child.raw_process_handle()) } == 0 {
            return Err(RuntimeProcessError::Unavailable);
        }

        use windows_sys::Win32::Foundation::{DUPLICATE_SAME_ACCESS, DuplicateHandle};
        use windows_sys::Win32::System::Threading::{GetCurrentProcess, GetProcessId};
        let mut duplicated = std::ptr::null_mut();
        let current = unsafe { GetCurrentProcess() };
        if unsafe {
            DuplicateHandle(
                current,
                child.raw_process_handle(),
                current,
                &mut duplicated,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        } == 0
        {
            return Err(RuntimeProcessError::Unavailable);
        }
        let process = OwnedHandle::new(duplicated).ok_or(RuntimeProcessError::Unavailable)?;
        let pid = unsafe { GetProcessId(process.0) };
        if pid == 0 {
            return Err(RuntimeProcessError::Unavailable);
        }

        Ok(Arc::new(WindowsRuntimeChild {
            child: Mutex::new(child),
            job,
            process,
            pid,
        }))
    }
}

#[async_trait]
impl RuntimeChild for WindowsRuntimeChild {
    fn verify_connection(&self, local: std::net::SocketAddr, peer: std::net::SocketAddr) -> bool {
        use windows_sys::Win32::Foundation::WAIT_TIMEOUT;
        use windows_sys::Win32::System::Threading::WaitForSingleObject;
        // Recheck liveness after querying the table; a dead child's old table
        // row must not authorize a replacement process. Written through named
        // operands rather than one chained `unsafe` expression: rustfmt mangles
        // the chained form into a non-compiling statement here.
        let alive = || unsafe { WaitForSingleObject(self.process.0, 0) == WAIT_TIMEOUT };
        alive() && connection_owned_by(self.pid, local, peer) && alive()
    }
    async fn wait(&self) -> Result<(), RuntimeProcessError> {
        // The supervisor calls `wait` once at a time, so a short lock is
        // enough and still lets a forced stop proceed while a wait is pending.
        self.child
            .lock()
            .await
            .wait()
            .await
            .map(|_| ())
            .map_err(|_| RuntimeProcessError::WaitFailed)
    }

    async fn graceful_stop(&self) -> Result<(), RuntimeProcessError> {
        // This pinned build exposes no cooperative shutdown request on a
        // windowless process, so a graceful stop terminates the job. The
        // supervisor still distinguishes the two requests in its own state
        // machine, and the AI slow path is asynchronous, so callers lose only
        // a pending request that was never a keystroke dependency.
        self.force_stop().await
    }

    async fn force_stop(&self) -> Result<(), RuntimeProcessError> {
        self.job.terminate()
    }
}

/// Authenticate the server side of this exact established IPv4 loopback
/// connection. Checking only a LISTEN row/port allows a reconnect race; matching
/// both endpoint addresses and ports binds the evidence to the existing socket.
fn connection_owned_by(pid: u32, local: std::net::SocketAddr, peer: std::net::SocketAddr) -> bool {
    use windows_sys::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, NO_ERROR};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        GetExtendedTcpTable, MIB_TCPROW_OWNER_PID, TCP_TABLE_OWNER_PID_ALL,
    };
    use windows_sys::Win32::Networking::WinSock::AF_INET;
    let (std::net::SocketAddr::V4(local), std::net::SocketAddr::V4(peer)) = (local, peer) else {
        return false;
    };
    if !local.ip().is_loopback() || !peer.ip().is_loopback() || pid == 0 {
        return false;
    }
    let mut needed = 0_u32;
    let result = unsafe {
        GetExtendedTcpTable(
            std::ptr::null_mut(),
            &mut needed,
            0,
            u32::from(AF_INET),
            TCP_TABLE_OWNER_PID_ALL,
            0,
        )
    };
    if result != ERROR_INSUFFICIENT_BUFFER || !(4..=4 * 1024 * 1024).contains(&needed) {
        return false;
    }
    // DWORD alignment, bounded allocation. A growing table is a safe rejection;
    // the caller may retry with a fresh connection on a later slow-path request.
    let mut buffer = vec![0_u32; (needed as usize).div_ceil(4)];
    let capacity = buffer.len() * 4;
    let result = unsafe {
        GetExtendedTcpTable(
            buffer.as_mut_ptr().cast(),
            &mut needed,
            0,
            u32::from(AF_INET),
            TCP_TABLE_OWNER_PID_ALL,
            0,
        )
    };
    if result != NO_ERROR || needed as usize > capacity || needed < 4 {
        return false;
    }
    let count = buffer[0] as usize;
    let row_size = std::mem::size_of::<MIB_TCPROW_OWNER_PID>();
    if count > (needed as usize - 4) / row_size {
        return false;
    }
    (0..count).any(|index| {
        // Both bounds and alignment are accounted for; read_unaligned also
        // avoids relying on the layout of a variable-length C table in Rust.
        let row = unsafe {
            std::ptr::read_unaligned(
                buffer
                    .as_ptr()
                    .cast::<u8>()
                    .add(4 + index * row_size)
                    .cast::<MIB_TCPROW_OWNER_PID>(),
            )
        };
        row.dwState == 5 // MIB_TCP_STATE_ESTAB
            && row.dwOwningPid == pid
            && row.dwLocalAddr.to_ne_bytes() == peer.ip().octets()
            && u16::from_be(row.dwLocalPort as u16) == peer.port()
            && row.dwRemoteAddr.to_ne_bytes() == local.ip().octets()
            && u16::from_be(row.dwRemotePort as u16) == local.port()
    })
}

/// Borrow the raw process handle from a tokio child without transferring
/// ownership, so the job assignment does not double-close it.
trait RawChildHandle {
    fn raw_process_handle(&self) -> windows_sys::Win32::Foundation::HANDLE;
}

impl RawChildHandle for Child {
    fn raw_process_handle(&self) -> windows_sys::Win32::Foundation::HANDLE {
        // A child without a live handle cannot be assigned to a job, so a
        // missing handle becomes a null handle and the caller fails closed.
        self.raw_handle()
            .map_or(std::ptr::null_mut(), |handle| handle.cast())
    }
}

#[cfg(test)]
mod tests {
    //! The substitution post-conditions are the fail-closed guard for an
    //! argument shape this crate does not control today: `launch_arguments` is
    //! produced by `local_runtime` from a reviewed manifest, so a caller-chosen
    //! value collision is exercised here against the resolver directly instead
    //! of through `from_plan`.

    use std::ffi::OsString;
    use std::path::{Path, PathBuf};

    use super::{
        KEY_FILE_FLAG, MODEL_FLAG, WindowsProcessError, connection_owned_by, resolve_arguments,
    };

    const MODEL: &str = "model/qwen2.5-1.5b-instruct-q4_k_m.gguf";
    const KEY: &str = "ai/runtime/api-key.txt";

    /// An installed root that needs no bytes on disk; the resolver never reads
    /// the filesystem.
    fn root() -> PathBuf {
        PathBuf::from(r"C:\Program Files\KanaAI")
    }

    /// Resolve `declared`, with `key` as both the declared key-file element and
    /// the value substituted for it. Using one value for both is what makes a
    /// collision a collision.
    fn resolve(declared: &[&str], key: &str) -> Result<Vec<OsString>, WindowsProcessError> {
        let declared: Vec<String> = declared.iter().map(|text| (*text).to_owned()).collect();
        resolve_arguments(&declared, &root().join(MODEL), &root().join(key))
    }

    /// How many elements of `arguments` are exactly `value`.
    fn element(arguments: &[OsString], value: &Path) -> usize {
        arguments
            .iter()
            .filter(|argument| argument.as_os_str() == value.as_os_str())
            .count()
    }

    #[test]
    fn the_reviewed_shape_substitutes_both_installed_values() {
        let arguments = resolve(&[MODEL_FLAG, MODEL, KEY_FILE_FLAG, KEY], KEY)
            .expect("the reviewed shape resolves");
        assert_eq!(element(&arguments, &root().join(MODEL)), 1, "{arguments:?}");
        assert_eq!(element(&arguments, &root().join(KEY)), 1, "{arguments:?}");
        assert_eq!(
            element(&arguments, Path::new(MODEL_FLAG)),
            1,
            "{arguments:?}"
        );
        assert_eq!(
            element(&arguments, Path::new(KEY_FILE_FLAG)),
            1,
            "{arguments:?}"
        );
    }

    #[test]
    fn a_key_path_equal_to_a_literal_rewrites_only_its_own_element() {
        // A text-matching substitution would rewrite every element equal to the
        // key path, so each value below is also a literal in the same vector:
        // `127.0.0.1` would rebind `--host`, `none` would change `--device`,
        // `49131` would change `--port`, and a flag would erase itself.
        for collision in ["127.0.0.1", "none", "49131", KEY_FILE_FLAG] {
            let declared = [
                MODEL_FLAG,
                MODEL,
                "--host",
                "127.0.0.1",
                "--device",
                "none",
                "--port",
                "49131",
                KEY_FILE_FLAG,
                collision,
            ];
            let arguments = resolve(&declared, collision)
                .expect("a colliding value is still resolved by position");
            // The literals keep their own value exactly once, so nothing was
            // rewritten to the installed path.
            assert_eq!(
                element(&arguments, Path::new("127.0.0.1")),
                1,
                "{collision}: {arguments:?}"
            );
            assert_eq!(
                element(&arguments, Path::new("none")),
                1,
                "{collision}: {arguments:?}"
            );
            assert_eq!(
                element(&arguments, Path::new("49131")),
                1,
                "{collision}: {arguments:?}"
            );
            assert_eq!(
                element(&arguments, Path::new(MODEL_FLAG)),
                1,
                "{collision}: {arguments:?}"
            );
            assert_eq!(
                element(&arguments, Path::new(KEY_FILE_FLAG)),
                1,
                "{collision}: {arguments:?}"
            );
            // The key path is present exactly once, as the value of its own flag.
            assert_eq!(
                element(&arguments, &root().join(collision)),
                1,
                "{collision}: {arguments:?}"
            );
        }
    }

    #[test]
    fn a_flag_without_a_value_fails_closed() {
        assert_eq!(
            resolve(&[MODEL_FLAG, MODEL, KEY_FILE_FLAG], KEY),
            Err(WindowsProcessError::ArgumentPlanMismatch)
        );
    }

    #[test]
    fn a_flag_swallowed_as_another_flags_value_fails_closed() {
        // The key-file flag is consumed as the model value, so the resolved key
        // path never appears. The post-condition fails closed instead of
        // starting a child with no `--api-key-file` at all.
        assert_eq!(
            resolve(&[MODEL_FLAG, KEY_FILE_FLAG, KEY], KEY),
            Err(WindowsProcessError::ArgumentPlanMismatch)
        );
    }

    #[test]
    fn a_second_copy_of_a_resolved_path_fails_closed() {
        // If the vector already carried the resolved model path somewhere else,
        // the substituted element would not be the only one and llama-server
        // would be left to decide which copy means what.
        let duplicate = root().join(MODEL).to_string_lossy().into_owned();
        let declared = [
            MODEL_FLAG,
            MODEL,
            "--alias",
            duplicate.as_str(),
            KEY_FILE_FLAG,
            KEY,
        ];
        assert_eq!(
            resolve(&declared, KEY),
            Err(WindowsProcessError::ArgumentPlanMismatch)
        );
    }

    #[test]
    fn an_established_loopback_connection_is_attributed_to_its_process() {
        // `connection_owned_by` had never executed before the peer-ownership
        // gate was wired into the readiness probe, so its correctness was an
        // assumption: a wrong state constant, a byte order mistake, or a table
        // layout the buffer arithmetic does not match would all report "not
        // owned" and silently keep the AI path off, or report a row that has
        // nothing to do with this connection. This exercises the real call
        // against a real established loopback connection, with both of its ends
        // in this process, so the answer must be true.
        use std::io::{Read, Write};
        use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};

        let listener =
            TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).expect("a listener");
        let server = listener.local_addr().expect("the listener address");
        let accepted = std::thread::spawn(move || {
            let (mut stream, peer) = listener.accept().expect("an accepted connection");
            assert_eq!(
                peer.ip(),
                Ipv4Addr::LOCALHOST,
                "the listener is loopback only"
            );
            // A completed exchange means the connection is ESTABLISHED in the
            // kernel's table rather than merely sitting in the accept backlog,
            // which is the state this function requires.
            let mut byte = [0_u8; 1];
            stream.read_exact(&mut byte).expect("the probe byte");
            stream.write_all(&byte).expect("the echo back");
            stream
        });
        let mut client = TcpStream::connect(server).expect("a loopback connect");
        client.write_all(b"x").expect("the probe byte leaves");
        let mut echoed = [0_u8; 1];
        client
            .read_exact(&mut echoed)
            .expect("the probe byte returns");
        let local = client.local_addr().expect("the client address");
        let peer_address = client.peer_addr().expect("the server address");
        let _server = accepted.join().expect("the server thread");

        assert!(
            connection_owned_by(std::process::id(), local, peer_address),
            "an established loopback connection of this process must be attributed to it"
        );
        // The owning pid is compared, not ignored: the first system process owns
        // nothing here, so its row cannot match. A build that dropped the
        // comparison would report the connection as owned by anyone.
        assert!(
            !connection_owned_by(1, local, peer_address),
            "a process that owns no such connection must not be credited with it"
        );
        // The loopback guard is load-bearing rather than incidental: a routable
        // endpoint pair is refused even though its ports are the same.
        assert!(
            !connection_owned_by(
                std::process::id(),
                SocketAddr::from(([10, 0, 0, 1], local.port())),
                peer_address,
            ),
            "a non-loopback endpoint must be refused"
        );
    }
}
