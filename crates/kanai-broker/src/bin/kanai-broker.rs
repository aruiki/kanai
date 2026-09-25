//! Local/Windows broker composition root.
//!
//! The Unix listener is a reproducible integration endpoint for WSL and CI;
//! Windows uses the same framed/authenticated dispatcher through the native
//! pipe adapter. The listener never enables a model by default: without an
//! explicit local policy it returns the Mozc baseline.

use kanai_broker::{
    EnhancementBackend, EnhancementError, EnhancementPolicy, LocalOpenAiBackend, ProviderLocality,
    RerankOutput, SemanticAssistOutput,
};

mod disabled_backend {
    use async_trait::async_trait;
    use kanai_broker::{
        CancellationToken, CandidateRerankRequest, EnhancementBackend, EnhancementError,
        ProviderLocality, RerankOutput, SemanticAssistOutput, SemanticAssistRequest,
    };

    pub struct DefaultEnhancementBackend;

    #[async_trait]
    impl EnhancementBackend for DefaultEnhancementBackend {
        fn provider_id(&self) -> &str {
            "disabled"
        }

        fn locality(&self) -> ProviderLocality {
            ProviderLocality::Local
        }

        async fn rerank(
            &self,
            _request: CandidateRerankRequest,
            _cancellation: CancellationToken,
        ) -> Result<RerankOutput, EnhancementError> {
            Err(EnhancementError::ProviderUnavailable(
                "no model runtime is bundled".to_owned(),
            ))
        }

        async fn semantic_assist(
            &self,
            _request: SemanticAssistRequest,
            _cancellation: CancellationToken,
        ) -> Result<SemanticAssistOutput, EnhancementError> {
            Err(EnhancementError::ProviderUnavailable(
                "no model runtime is bundled".to_owned(),
            ))
        }
    }
}

enum ConfiguredBackend {
    Disabled(disabled_backend::DefaultEnhancementBackend),
    Local(LocalOpenAiBackend),
}

#[async_trait::async_trait]
impl EnhancementBackend for ConfiguredBackend {
    fn provider_id(&self) -> &str {
        match self {
            Self::Disabled(backend) => backend.provider_id(),
            Self::Local(backend) => backend.provider_id(),
        }
    }

    fn locality(&self) -> ProviderLocality {
        match self {
            Self::Disabled(backend) => backend.locality(),
            Self::Local(backend) => backend.locality(),
        }
    }

    async fn rerank(
        &self,
        request: kanai_broker::CandidateRerankRequest,
        cancellation: kanai_broker::CancellationToken,
    ) -> Result<RerankOutput, EnhancementError> {
        match self {
            Self::Disabled(backend) => backend.rerank(request, cancellation).await,
            Self::Local(backend) => backend.rerank(request, cancellation).await,
        }
    }

    async fn semantic_assist(
        &self,
        request: kanai_broker::SemanticAssistRequest,
        cancellation: kanai_broker::CancellationToken,
    ) -> Result<SemanticAssistOutput, EnhancementError> {
        match self {
            Self::Disabled(backend) => backend.semantic_assist(request, cancellation).await,
            Self::Local(backend) => backend.semantic_assist(request, cancellation).await,
        }
    }
}

fn configured_backend() -> ConfiguredBackend {
    if matches!(
        std::env::var("KANAI_BROKER_ENHANCEMENT").as_deref(),
        Ok("local" | "local-only")
    ) && let Some(backend) = LocalOpenAiBackend::from_environment()
    {
        ConfiguredBackend::Local(backend)
    } else {
        ConfiguredBackend::Disabled(disabled_backend::DefaultEnhancementBackend)
    }
}

#[cfg(unix)]
mod unix_listener {
    use std::error::Error;
    use std::fs;
    use std::os::unix::fs::{FileTypeExt, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    use kanai_broker::{
        BrokerConfig, DEFAULT_MAX_FRAME_BYTES, EnhancementQueue, FramedIo, MozcSessionBackend,
        SessionBroker, SharedSecret, SharedSecretAuthenticator, serve_authenticated_request,
    };
    use kanai_mozc::MozcBridgeConfig;

    use super::configured_backend;

    pub async fn run() -> Result<(), Box<dyn Error>> {
        let socket = socket_path();
        if socket.exists() {
            let metadata = fs::symlink_metadata(&socket)?;
            if !metadata.file_type().is_socket() {
                return Err(
                    format!("refusing to replace non-socket path {}", socket.display()).into(),
                );
            }
            fs::remove_file(&socket)?;
        }
        if let Some(parent) = socket.parent() {
            fs::create_dir_all(parent)?;
        }
        let secret = std::env::var("KANAI_BROKER_SECRET")
            .map_err(|_| "KANAI_BROKER_SECRET is required for the local listener")?;
        let secret = SharedSecret::new(secret.into_bytes())?;
        let authenticator = Arc::new(SharedSecretAuthenticator::new(
            secret,
            Some("KanaAI.MozcServer".to_owned()),
        ));
        let broker = Arc::new(SessionBroker::with_config(
            MozcSessionBackend::new(MozcBridgeConfig::from_environment()),
            BrokerConfig {
                max_sessions: 32,
                ..BrokerConfig::default()
            },
        ));
        let policy = super::enhancement_policy();
        let queue = Arc::new(EnhancementQueue::start(configured_backend(), policy, 4, 2)?);
        let listener = UnixListener::bind(&socket)?;
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
        println!("kanai-broker listening on {}", socket.display());

        // The std listener is used only to accept a connection. Keep one
        // runtime context for the broker-owned Mozc children and queue; making
        // a fresh runtime per connection would invalidate Tokio process I/O
        // when that connection closes. The blocking socket work stays on its
        // own OS thread, while `Handle::block_on` preserves the main runtime
        // context for async session/provider tasks.
        let runtime = tokio::runtime::Handle::current();
        loop {
            let (stream, _) = listener.accept()?;
            let broker = Arc::clone(&broker);
            let queue = Arc::clone(&queue);
            let authenticator = Arc::clone(&authenticator);
            let runtime = runtime.clone();
            std::thread::spawn(move || {
                if let Err(error) = stream.set_read_timeout(Some(Duration::from_secs(2))) {
                    eprintln!("kanai-broker socket read-timeout setup failed: {error}");
                    return;
                }
                if let Err(error) = stream.set_write_timeout(Some(Duration::from_secs(2))) {
                    eprintln!("kanai-broker socket write-timeout setup failed: {error}");
                    return;
                }
                let transport = match FramedIo::new(stream, DEFAULT_MAX_FRAME_BYTES) {
                    Ok(transport) => transport,
                    Err(error) => {
                        eprintln!("kanai-broker transport setup failed: {error}");
                        return;
                    }
                };
                if let Err(error) = runtime.block_on(serve_authenticated_request(
                    transport,
                    broker,
                    queue,
                    authenticator,
                )) {
                    eprintln!("kanai-broker connection closed: {error}");
                }
            });
        }
    }

    fn socket_path() -> PathBuf {
        std::env::var_os("KANAI_BROKER_SOCKET")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::temp_dir().join(format!("kanai-broker-{}.sock", std::process::id()))
            })
    }
}

#[cfg(windows)]
mod windows_listener {
    use std::error::Error;
    use std::sync::Arc;

    use kanai_broker::{
        BrokerConfig, EnhancementQueue, MozcSessionBackend, SessionBroker,
        WindowsPeerAuthenticator, serve_named_pipe,
    };
    use kanai_mozc::MozcBridgeConfig;
    use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
    use windows_sys::Win32::System::Threading::GetCurrentProcessId;

    use super::configured_backend;

    pub async fn run() -> Result<(), Box<dyn Error>> {
        let broker = Arc::new(SessionBroker::with_config(
            MozcSessionBackend::new(MozcBridgeConfig::from_environment()),
            BrokerConfig {
                max_sessions: 32,
                ..BrokerConfig::default()
            },
        ));
        let policy = super::enhancement_policy();
        let queue = Arc::new(EnhancementQueue::start(configured_backend(), policy, 4, 2)?);
        let pipe_name = std::env::var("KANAI_AI_TSF_PIPE")
            .unwrap_or_else(|_| format!("\\\\.\\pipe\\KanaAI.TsfBroker.v1.{}", session_id()));
        println!("kanai-broker listening on {pipe_name}");
        serve_named_pipe(pipe_name, broker, queue, |handle| {
            Arc::new(WindowsPeerAuthenticator::new(handle, "KanaAI.MozcServer"))
        })
        .await?;
        Ok(())
    }

    fn session_id() -> u32 {
        let mut session = 0;
        let ok = unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) };
        if ok == 0 { 0 } else { session }
    }
}

fn enhancement_policy() -> EnhancementPolicy {
    match std::env::var("KANAI_BROKER_ENHANCEMENT").as_deref() {
        Ok("local") | Ok("local-only") => EnhancementPolicy::LocalQualityOnly,
        _ => EnhancementPolicy::Disabled,
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(unix)]
    {
        unix_listener::run().await
    }
    #[cfg(windows)]
    {
        windows_listener::run().await
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err("kanai-broker has no listener for this platform".into())
    }
}
