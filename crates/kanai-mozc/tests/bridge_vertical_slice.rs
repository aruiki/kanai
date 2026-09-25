//! Real-process coverage for the lab Mozc -> candidate pipeline.
//!
//! The test is intentionally skipped when the optional C++ bridge has not been
//! built.  CI can run it after the pinned Bazel target is available; local
//! development gets a concrete end-to-end check instead of a fake provider.

use std::path::PathBuf;
use std::time::Duration;

use kanai_core::{
    CandidatePipeline, ConversionProvider, ConversionRequest, LocalDataPolicy, LocalQualityConfig,
    ModelTier, PipelineSession, ProviderError,
};
use kanai_mozc::{MozcBridge, MozcBridgeConfig, MozcBridgePool, MozcKey, MozcSessionClient};

fn bridge_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("KANAI_MOZC_BRIDGE") {
        let path = PathBuf::from(path);
        return path.is_file().then_some(path);
    }
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../third_party/mozc/src/bazel-bin/kanai/kanai_mozc_bridge");
    path.is_file().then_some(path)
}

#[tokio::test]
async fn real_multiplexed_bridge_rejects_invalid_stale_and_replayed_commits() {
    let Some(binary_path) = bridge_path() else {
        if std::env::var("KANAI_REQUIRE_MOZC_BRIDGE").is_ok() {
            panic!("KANAI_MOZC_BRIDGE is required for this integration test");
        }
        eprintln!("skipping multiplexed bridge test: build //kanai:kanai_mozc_bridge first");
        return;
    };
    let profile = tempfile::tempdir().expect("temporary Mozc profile");
    let pool = MozcBridgePool::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    });
    let first = MozcSessionClient::new(pool.clone(), 101);
    let second = MozcSessionClient::new(pool, 102);
    first.open().await.expect("open first session");
    second.open().await.expect("open second session");

    first
        .key(&MozcKey::Character("kyou".to_owned()), 0)
        .await
        .expect("first key");
    second
        .key(&MozcKey::Character("asa".to_owned()), 0)
        .await
        .expect("second key");

    let mut first_request = ConversionRequest::new("kyou");
    first_request.revision = 2;
    let first_result = first
        .convert(&first_request)
        .await
        .expect("first conversion");
    assert!(!first_result.candidates.is_empty());
    let selected = first_result.candidates[0].id;

    let unknown = first.commit(i32::MIN, 2).await;
    assert!(matches!(unknown, Err(ProviderError::Protocol(_))));
    let stale = first.commit(selected, 1).await;
    assert!(matches!(stale, Err(ProviderError::Protocol(_))));

    // A valid snapshot can still be committed after rejected attempts. The
    // selected id may be zero or negative in Mozc; membership, not sign, is
    // the validity rule.
    first
        .commit(selected, 2)
        .await
        .expect("selected candidate commits");
    let replay = first.commit(selected, 2).await;
    assert!(matches!(replay, Err(ProviderError::Protocol(_))));

    // A stale close must not tear down a live session, and the valid close
    // consumes the exact post-commit generation.
    assert!(matches!(
        first.close_at(Some(2)).await,
        Err(ProviderError::Protocol(_))
    ));
    first
        .close_at(Some(3))
        .await
        .expect("generation-checked close");
    assert!(matches!(
        first.close_at(Some(3)).await,
        Err(ProviderError::Protocol(_))
    ));

    // Closing one session leaves the other upstream session independently
    // usable.
    let mut second_request = ConversionRequest::new("asa");
    second_request.revision = 2;
    let second_result = second
        .convert(&second_request)
        .await
        .expect("second conversion after first close");
    assert!(!second_result.candidates.is_empty());
    second
        .commit(second_result.candidates[0].id, 2)
        .await
        .expect("second candidate commits");
    second.close_at(Some(3)).await.expect("second close");
}

#[tokio::test]
async fn real_mozc_convert_accepts_rendered_japanese_without_slow_update_composition() {
    let Some(binary_path) = bridge_path() else {
        if std::env::var("KANAI_REQUIRE_MOZC_BRIDGE").is_ok() {
            panic!("KANAI_MOZC_BRIDGE is required for this integration test");
        }
        eprintln!(
            "skipping rendered Japanese conversion test: build //kanai:kanai_mozc_bridge first"
        );
        return;
    };
    let profile = tempfile::tempdir().expect("temporary Mozc profile");
    let pool = MozcBridgePool::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    });
    let session = MozcSessionClient::new(pool, 201);
    session
        .open()
        .await
        .expect("open Japanese conversion session");
    let mut request = ConversionRequest::new("きょう");
    request.revision = 1;
    let result = session
        .convert(&request)
        .await
        .expect("rendered Japanese conversion");
    assert!(!result.candidates.is_empty());
    session
        .close_at(Some(1))
        .await
        .expect("close Japanese session");
}

#[tokio::test]
async fn real_mozc_candidates_flow_through_fast_pipeline_and_commit() {
    let Some(binary_path) = bridge_path() else {
        eprintln!("skipping real Mozc bridge test: build //kanai:kanai_mozc_bridge first");
        return;
    };
    let profile = tempfile::tempdir().expect("temporary Mozc profile");
    let bridge = MozcBridge::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    });
    assert!(bridge.health().await.available);

    let mut request = ConversionRequest::new("kyou");
    request.context_before = "会議の開始は".to_owned();
    request.context_after = "。".to_owned();
    request.revision = 42;
    let session = PipelineSession::new(1, request.revision, ModelTier::Compact);
    let mut pipeline =
        CandidatePipeline::new(LocalQualityConfig::new(LocalDataPolicy::BoundedContext));
    let output = pipeline
        .convert_fast(&bridge, &request, session, None, 0)
        .await
        .expect("real Mozc conversion");

    assert!(!output.result.candidates.is_empty());
    assert!(!output.candidates.is_empty());
    assert_eq!(output.session.generation, request.revision);
    assert!(output.context.before().contains("会議"));

    let selected = output.candidates[0].candidate.id;
    let stale = bridge
        .commit_at(selected, request.revision - 1)
        .await
        .expect_err("a stale generation must not reach Mozc commit");
    assert!(matches!(stale, kanai_core::ProviderError::Protocol(_)));

    let commit = bridge
        .commit_at(selected, request.revision)
        .await
        .expect("selected Mozc candidate commits");
    assert!(!commit.text.is_empty());
    assert!(
        !profile.path().join("mozc/.history.db").exists(),
        "incognito bridge must not create a second persistent history"
    );
}
