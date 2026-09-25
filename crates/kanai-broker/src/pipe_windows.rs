//! Windows named-pipe server for the canonical broker protocol.
//!
//! This module is compiled only on Windows. It uses Tokio's overlapped pipe
//! implementation, a protected SDDL, `PIPE_REJECT_REMOTE_CLIENTS`, and an OS
//! token authenticator. The public proof field is only a protocol marker; the
//! authenticator below checks the connected pipe's process image, Windows
//! session, and user SID before accepting it. Set
//! `KANAI_AI_TSF_CLIENT_IMAGE` to pin an exact host image when the default
//! Mozc server executable names are not appropriate.

use std::env;
use std::ffi::c_void;
use std::io;
use std::mem::size_of;
use std::os::windows::io::AsRawHandle;
use std::ptr;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::{NamedPipeServer, PipeMode, ServerOptions};
use tokio::time::{Duration, timeout};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{
    GetLengthSid, GetTokenInformation, IsValidSid, TOKEN_QUERY, TokenUser,
};
use windows_sys::Win32::System::Pipes::{GetNamedPipeClientProcessId, GetNamedPipeClientSessionId};
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};

use crate::{
    AuthRequest, AuthResponse, AuthenticatedPeer, DEFAULT_MAX_FRAME_BYTES, EnhancementBackend,
    EnhancementQueue, FRAME_HEADER_BYTES, FRAME_MAGIC, Frame, PeerAuthenticator, RequestCommand,
    SessionBackend, SessionBroker, decode_request,
};

const PEER_MARKER: &[u8] = b"KanaAI.Tsf.TokenPeer.v1";
// Owner Rights (OW) is the process owner. The additional OS token check below
// makes the ACL and peer validation independent of the public proof marker.
const PIPE_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;OW)";

struct PipeSecurity {
    descriptor: *mut c_void,
    attributes: windows_sys::Win32::Security::SECURITY_ATTRIBUTES,
}

impl PipeSecurity {
    fn new() -> io::Result<Self> {
        let sddl = PIPE_SDDL
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect::<Vec<_>>();
        let mut descriptor = ptr::null_mut();
        let converted = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                ptr::null_mut(),
            )
        };
        if converted == 0 || descriptor.is_null() {
            return Err(io::Error::last_os_error());
        }
        let attributes = windows_sys::Win32::Security::SECURITY_ATTRIBUTES {
            nLength: size_of::<windows_sys::Win32::Security::SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        Ok(Self {
            descriptor,
            attributes,
        })
    }
}

impl Drop for PipeSecurity {
    fn drop(&mut self) {
        if !self.descriptor.is_null() {
            unsafe {
                windows_sys::Win32::Foundation::LocalFree(self.descriptor as _);
            }
        }
    }
}

struct OwnedHandle(HANDLE);

impl OwnedHandle {
    fn new(handle: HANDLE) -> io::Result<Self> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(handle))
        }
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

/// Per-connection OS authenticator for the native TSF client.
pub struct WindowsPeerAuthenticator {
    // HANDLE is a raw pointer and is not automatically Send/Sync. The value
    // is only used as an opaque per-connection handle; it never escapes the
    // connection task after construction.
    pipe: usize,
    client_id: String,
    allowed_client_image: Option<String>,
}

impl WindowsPeerAuthenticator {
    #[must_use]
    pub fn new(pipe: HANDLE, client_id: impl Into<String>) -> Self {
        let client_id = client_id.into();
        let allowed_client_image = env::var("KANAI_AI_TSF_CLIENT_IMAGE")
            .ok()
            .filter(|value| !value.trim().is_empty());
        Self {
            pipe: pipe as usize,
            client_id,
            allowed_client_image,
        }
    }
}

impl PeerAuthenticator for WindowsPeerAuthenticator {
    fn authenticate(
        &self,
        request: &AuthRequest,
    ) -> Result<AuthenticatedPeer, crate::TransportError> {
        request.validate()?;
        if request.client_id != self.client_id || request.proof != PEER_MARKER {
            return Err(crate::TransportError::PeerRejected(
                "client identity or capability marker was rejected".to_owned(),
            ));
        }
        let pipe = self.pipe as HANDLE;
        if !same_windows_session(pipe) {
            return Err(crate::TransportError::PeerRejected(
                "pipe client is not in the broker session".to_owned(),
            ));
        }
        if !same_user(pipe) {
            return Err(crate::TransportError::PeerRejected(
                "pipe client user does not match the broker owner".to_owned(),
            ));
        }
        let client_image = client_process_image(pipe).ok_or_else(|| {
            crate::TransportError::PeerRejected(
                "pipe client process image could not be verified".to_owned(),
            )
        })?;
        if !allowed_client_image(
            &client_image,
            &self.client_id,
            self.allowed_client_image.as_deref(),
        ) {
            return Err(crate::TransportError::PeerRejected(
                "pipe client process image is not an approved KanaAI host".to_owned(),
            ));
        }
        Ok(AuthenticatedPeer {
            client_id: request.client_id.clone(),
        })
    }
}

/// Maximum number of simultaneously serviced named-pipe connections.
///
/// A model exchange is deliberately allowed to take longer than a key
/// exchange.  A single-instance listener would let one slow optional request
/// head-of-line-block every later TSF connection, so the listener keeps a
/// small bounded set of instances and services each connection independently.
const MAX_PIPE_INSTANCES: usize = 8;

/// Run the named-pipe listener until the process is stopped.
///
/// `make_authenticator` is called after each client connects so it can bind
/// the OS pipe handle into the peer check. Each connection handles one
/// canonical request, but connections are serviced concurrently up to
/// [`MAX_PIPE_INSTANCES`]. Session state remains serialized by the broker's
/// per-session operation lock; optional work remains outside that lock.
pub async fn serve_named_pipe<B, E, F>(
    pipe_name: impl Into<String>,
    broker: Arc<SessionBroker<B>>,
    queue: Arc<EnhancementQueue<E>>,
    mut make_authenticator: F,
) -> io::Result<()>
where
    B: SessionBackend + 'static,
    E: EnhancementBackend + Send + Sync + 'static,
    F: FnMut(HANDLE) -> Arc<dyn PeerAuthenticator>,
{
    let pipe_name = pipe_name.into();
    let mut security = PipeSecurity::new()?;
    let mut first_instance = true;
    loop {
        let mut options = ServerOptions::new();
        options
            .first_pipe_instance(first_instance)
            .reject_remote_clients(true)
            .max_instances(MAX_PIPE_INSTANCES)
            .pipe_mode(PipeMode::Byte);
        let server = unsafe {
            options.create_with_security_attributes_raw(
                pipe_name.as_str(),
                &mut security.attributes as *mut _ as *mut c_void,
            )?
        };
        first_instance = false;
        if let Err(error) = server.connect().await {
            eprintln!("kanai-broker pipe connect failed: {error}");
            continue;
        }
        let authenticator = make_authenticator(server.as_raw_handle() as HANDLE);
        let broker = Arc::clone(&broker);
        let queue = Arc::clone(&queue);
        tokio::spawn(async move {
            let mut server = server;
            if let Err(error) = serve_connected(&mut server, broker, queue, authenticator).await {
                eprintln!("kanai-broker pipe connection closed: {error}");
            }
            let _ = server.disconnect();
        });
    }
}

async fn serve_connected<B, E>(
    server: &mut NamedPipeServer,
    broker: Arc<SessionBroker<B>>,
    queue: Arc<EnhancementQueue<E>>,
    authenticator: Arc<dyn PeerAuthenticator>,
) -> io::Result<()>
where
    B: SessionBackend,
    E: EnhancementBackend + Send + Sync + 'static,
{
    let auth_payload = timeout(Duration::from_secs(2), read_frame(server))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "broker auth deadline"))??;
    let request: AuthRequest = serde_json::from_slice(&auth_payload)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let peer = match authenticator.authenticate(&request) {
        Ok(peer) => peer,
        Err(_) => {
            write_json(
                server,
                &AuthResponse::rejected("peer authentication failed"),
            )
            .await?;
            return Ok(());
        }
    };
    write_json(server, &AuthResponse::accepted(peer.clone())).await?;
    let payload = timeout(Duration::from_secs(2), read_frame(server))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "broker request deadline"))??;
    let request = decode_request(&payload)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if let RequestCommand::Cancel(command) = &request.command
        && let Some(target) = command.target_request_id
        && broker
            .session_owned_by(command.session_id, &peer.client_id)
            .await
    {
        queue.cancel_request(target);
    }
    let cancellation = crate::CancellationToken::new();
    let response = match timeout(Duration::from_secs(5), async {
        if matches!(
            &request.command,
            RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_)
        ) {
            broker
                .submit_enhancement_for_peer(
                    request.clone(),
                    queue.as_ref(),
                    cancellation.clone(),
                    &peer.client_id,
                )
                .await
        } else {
            broker.handle_for_peer(request, &peer.client_id).await
        }
    })
    .await
    {
        Ok(response) => response,
        Err(_) => {
            cancellation.cancel();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "broker dispatch deadline",
            ));
        }
    };
    write_json(server, &response).await?;
    let _ = server.disconnect();
    Ok(())
}

async fn read_frame(server: &mut NamedPipeServer) -> io::Result<Vec<u8>> {
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    server.read_exact(&mut header).await?;
    if header[..FRAME_MAGIC.len()] != FRAME_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid broker frame magic",
        ));
    }
    let length = u32::from_be_bytes(header[4..8].try_into().expect("fixed header")) as usize;
    if length == 0 || length > DEFAULT_MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "broker frame length is outside the limit",
        ));
    }
    let mut payload = vec![0_u8; length];
    server.read_exact(&mut payload).await?;
    Ok(payload)
}

async fn write_json<T: serde::Serialize>(
    server: &mut NamedPipeServer,
    value: &T,
) -> io::Result<()> {
    let payload = serde_json::to_vec(value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let frame =
        Frame::new(payload).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    server.write_all(&frame_codec(&frame)).await?;
    server.flush().await
}

fn frame_codec(frame: &Frame) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(FRAME_HEADER_BYTES + frame.len());
    bytes.extend_from_slice(&FRAME_MAGIC);
    bytes.extend_from_slice(&(frame.len() as u32).to_be_bytes());
    bytes.extend_from_slice(frame.payload());
    bytes
}

fn process_image_name(pid: u32) -> Option<String> {
    let process =
        OwnedHandle::new(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) }).ok()?;
    let mut buffer = vec![0_u16; 32_768];
    let mut length = buffer.len() as u32;
    if unsafe {
        QueryFullProcessImageNameW(
            process.0,
            PROCESS_NAME_WIN32,
            buffer.as_mut_ptr(),
            &mut length,
        )
    } == 0
    {
        return None;
    }
    String::from_utf16(buffer.get(..length as usize)?).ok()
}

fn client_process_image(pipe: HANDLE) -> Option<String> {
    let mut pid = 0_u32;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 {
        return None;
    }
    process_image_name(pid)
}

fn image_basename(path: &str) -> &str {
    path.rsplit(['\\', '/']).next().unwrap_or(path)
}

fn normalized_image_path(path: &str) -> String {
    path.trim()
        .trim_end_matches(['\\', '/'])
        .to_ascii_lowercase()
}

fn allowed_client_image(image: &str, client_id: &str, configured_image: Option<&str>) -> bool {
    if let Some(expected) = configured_image {
        return normalized_image_path(image) == normalized_image_path(expected);
    }
    if client_id != "KanaAI.MozcServer" {
        return false;
    }
    matches!(
        image_basename(image).to_ascii_lowercase().as_str(),
        "mozc_server_win.exe" | "mozc_server.exe" | "kanai_mozc_bridge.exe"
    )
}

fn same_windows_session(pipe: HANDLE) -> bool {
    let mut client_session = 0_u32;
    if unsafe { GetNamedPipeClientSessionId(pipe, &mut client_session) } == 0 {
        return false;
    }
    let mut current_session = 0_u32;
    unsafe {
        ProcessIdToSessionId(GetCurrentProcessId(), &mut current_session) != 0
            && client_session == current_session
    }
}

fn same_user(pipe: HANDLE) -> bool {
    let mut client_pid = 0_u32;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut client_pid) } == 0 {
        return false;
    }
    let Ok(client_process) =
        OwnedHandle::new(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, client_pid) })
    else {
        return false;
    };
    let mut client_token = ptr::null_mut();
    if unsafe { OpenProcessToken(client_process.0, TOKEN_QUERY, &mut client_token) } == 0 {
        return false;
    }
    let client_token = match OwnedHandle::new(client_token) {
        Ok(token) => token,
        Err(_) => return false,
    };
    let mut current_token = ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut current_token) } == 0 {
        return false;
    }
    let current_token = match OwnedHandle::new(current_token) {
        Ok(token) => token,
        Err(_) => return false,
    };
    match (token_user(client_token.0), token_user(current_token.0)) {
        (Some(client), Some(current)) => client == current,
        _ => false,
    }
}

fn token_user(token: HANDLE) -> Option<Vec<u8>> {
    let mut length = 0_u32;
    unsafe {
        GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut length);
    }
    if length == 0 {
        return None;
    }
    let mut buffer = vec![0_usize; (length as usize).div_ceil(size_of::<usize>())];
    let ok = unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr() as *mut c_void,
            length,
            &mut length,
        )
    };
    if ok == 0 {
        return None;
    }
    let token_user = buffer.as_ptr() as *const windows_sys::Win32::Security::TOKEN_USER;
    let sid = unsafe { (*token_user).User.Sid };
    if sid.is_null() || unsafe { IsValidSid(sid) } == 0 {
        return None;
    }
    let sid_length = unsafe { GetLengthSid(sid) } as usize;
    if sid_length == 0 {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(sid as *const u8, sid_length) }.to_vec())
}

#[cfg(test)]
mod tests {
    use super::{allowed_client_image, image_basename, normalized_image_path};

    #[test]
    fn image_allowlist_accepts_only_known_mozc_host_names_or_exact_override() {
        assert!(allowed_client_image(
            r"C:\Program Files\KanaAI\mozc_server_win.exe",
            "KanaAI.MozcServer",
            None,
        ));
        assert!(!allowed_client_image(
            r"C:\Temp\notepad.exe",
            "KanaAI.MozcServer",
            None,
        ));
        assert!(allowed_client_image(
            r"C:\KanaAI\custom-host.exe",
            "KanaAI.MozcServer",
            Some(r"C:\KanaAI\custom-host.exe"),
        ));
        assert!(allowed_client_image(
            r"c:\kanaai\CUSTOM-HOST.EXE",
            "KanaAI.MozcServer",
            Some(r"C:\KanaAI\custom-host.exe"),
        ));
        assert!(!allowed_client_image(
            r"C:\KanaAI-Other\custom-host.exe",
            "KanaAI.MozcServer",
            Some(r"C:\KanaAI\custom-host.exe"),
        ));
        assert_eq!(
            image_basename(r"C:\KanaAI\mozc_server_win.exe"),
            "mozc_server_win.exe"
        );
        assert_eq!(normalized_image_path(r"C:\KanaAI\"), r"c:\kanaai");
    }
}
