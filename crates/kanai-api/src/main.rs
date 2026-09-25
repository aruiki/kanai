use std::env;
use std::net::SocketAddr;

use anyhow::Context;
use kanai_api::{AppState, AssistantConfig, app};
use kanai_core::{CandidatePipeline, LocalDataPolicy, LocalQualityConfig};
use kanai_mozc::MozcBridge;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let address = SocketAddr::from((
        [127, 0, 0, 1],
        env::var("KANAI_PORT")
            .or_else(|_| env::var("AI_PORT"))
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(8787),
    ));
    let state = AppState {
        provider: std::sync::Arc::new(MozcBridge::from_environment()),
        assistant: AssistantConfig::from_environment(),
        pipeline: std::sync::Arc::new(tokio::sync::Mutex::new(CandidatePipeline::new(
            LocalQualityConfig::new(LocalDataPolicy::BoundedContext),
        ))),
    };
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .with_context(|| format!("failed to bind {address}"))?;
    info!(%address, "KanaAI local service started");
    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("HTTP server failed")
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}
