mod reranker;

pub use reranker::{AiMode, AiRerankInfo, AiRerankStatus};

use std::env;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{DefaultBodyLimit, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use kanai_core::{
    CommitResult, ConversionProvider, ConversionRequest, HardwareCapabilities, LearningState,
    ModelProfile, ProviderHealth, UserProfile, UserWord, recommend_tier_for_memory,
};
use serde::{Deserialize, Serialize};
use sysinfo::System;
use tokio::time::timeout;
use tower_http::services::{ServeDir, ServeFile};
use tower_http::trace::TraceLayer;

const MAX_ASSIST_CHARS: usize = 4_000;
const MAX_CONVERSION_CANDIDATES: usize = 20;

#[derive(Clone)]
pub struct AppState {
    pub provider: Arc<dyn ConversionProvider>,
    pub assistant: AssistantConfig,
}

#[derive(Clone)]
pub struct AssistantConfig {
    api_key: Option<String>,
    base_url: String,
    model: Option<String>,
    allow_remote: bool,
}

impl AssistantConfig {
    #[must_use]
    pub fn from_environment() -> Self {
        Self {
            api_key: env::var("KANA_AI_API_KEY")
                .ok()
                .filter(|value| !value.is_empty()),
            base_url: env::var("KANA_AI_BASE_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:8080/v1".to_owned())
                .trim_end_matches('/')
                .to_owned(),
            model: env::var("KANA_AI_MODEL")
                .ok()
                .filter(|value| !value.is_empty()),
            allow_remote: env::var("KANA_AI_ALLOW_REMOTE")
                .is_ok_and(|value| value == "1" || value.eq_ignore_ascii_case("true")),
        }
    }

    fn endpoint_url(&self) -> Option<reqwest::Url> {
        let url = reqwest::Url::parse(&self.base_url).ok()?;
        let valid_scheme = matches!(url.scheme(), "http" | "https");
        let no_credentials = url.username().is_empty() && url.password().is_none();
        let no_query_or_fragment = url.query().is_none() && url.fragment().is_none();
        (valid_scheme && no_credentials && no_query_or_fragment && url.host_str().is_some())
            .then_some(url)
    }

    fn is_loopback(&self) -> bool {
        self.endpoint_url().is_some_and(|url| {
            url.host_str().is_some_and(|host| {
                host.eq_ignore_ascii_case("localhost")
                    || host
                        .parse::<IpAddr>()
                        .is_ok_and(|address| address.is_loopback())
            })
        })
    }

    fn is_endpoint_allowed(&self) -> bool {
        self.is_loopback()
            || (self.allow_remote
                && self
                    .endpoint_url()
                    .is_some_and(|url| url.scheme() == "https"))
    }

    fn is_rerank_ready(&self) -> bool {
        self.model.is_some() && self.is_loopback()
    }

    fn is_assistant_ready(&self) -> bool {
        self.model.is_some() && self.is_endpoint_allowed()
    }

    fn public_endpoint(&self) -> String {
        self.endpoint_url().map_or_else(
            || "invalid-or-disabled".to_owned(),
            |mut url| {
                let _ = url.set_username("");
                let _ = url.set_password(None);
                url.set_query(None);
                url.set_fragment(None);
                url.to_string().trim_end_matches('/').to_owned()
            },
        )
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertRequest {
    romaji: String,
    #[serde(default)]
    context_before: String,
    #[serde(default)]
    context_after: String,
    #[serde(default = "default_limit")]
    limit: usize,
    #[serde(default)]
    ai_mode: AiMode,
    #[serde(default)]
    state: LearningState,
}

const fn default_limit() -> usize {
    9
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalizedConversionResult {
    pub provider: String,
    pub reading: String,
    pub preedit: String,
    pub preedit_segments: Vec<kanai_core::PreeditSegment>,
    pub candidates: Vec<kanai_core::PersonalizedCandidate>,
    pub focused_index: Option<usize>,
    pub consumed: bool,
    pub elapsed: Duration,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertResponse {
    result: PersonalizedConversionResult,
    state: LearningState,
    #[serde(skip_serializing_if = "Option::is_none")]
    ai: Option<AiRerankInfo>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitRequest {
    candidate_id: i32,
    reading: String,
    expected_text: String,
    context: String,
    #[serde(default)]
    state: LearningState,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResponse {
    result: CommitResult,
    state: LearningState,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StateRequest {
    #[serde(rename = "state", default)]
    _state: LearningState,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateResponse {
    state: LearningState,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileRequest {
    profile: UserProfile,
    #[serde(default)]
    state: LearningState,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserWordRequest {
    reading: String,
    text: String,
    #[serde(default = "default_word_boost")]
    boost: f64,
    #[serde(default)]
    state: LearningState,
}

const fn default_word_boost() -> f64 {
    180.0
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveUserWordRequest {
    id: String,
    #[serde(default)]
    state: LearningState,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiRuntimeConfig {
    reranker_ready: bool,
    endpoint_allowed: bool,
    remote_allowed: bool,
    model: Option<String>,
    endpoint: String,
    rerank_timeout_millis: u64,
    max_rerank_candidates: usize,
    minimum_confidence: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigResponse {
    name: &'static str,
    version: &'static str,
    assistant_configured: bool,
    assistant_model: Option<String>,
    assistant_endpoint: String,
    model_profiles: Vec<ModelProfile>,
    ai_runtime: AiRuntimeConfig,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCatalogResponse {
    runtime: &'static str,
    active_model: Option<String>,
    endpoint: String,
    profiles: Vec<ModelProfile>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelHealthResponse {
    status: String,
    reranker_ready: bool,
    model: Option<String>,
    endpoint: String,
    detail: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistRequest {
    text: String,
    #[serde(default)]
    instruction: String,
    #[serde(default)]
    personalize: bool,
    #[serde(default)]
    state: LearningState,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistResponse {
    text: String,
    provider: String,
    notice: Option<String>,
}

pub fn app(state: AppState) -> Router {
    let static_files = ServeDir::new("dist").not_found_service(ServeFile::new("dist/index.html"));
    let api = Router::new()
        .layer(DefaultBodyLimit::max(128 * 1024))
        .route("/health", get(health))
        .route("/config", get(config))
        .route("/system", get(system))
        .route("/models", get(models))
        .route("/model/health", get(model_health))
        .route("/convert", post(convert))
        .route("/commit", post(commit))
        .route("/state/reset", post(reset_state))
        .route("/state/profile", post(update_profile))
        .route("/user-words", post(add_user_word))
        .route("/user-words/remove", post(remove_user_word))
        .route("/assist", post(assist))
        .fallback(api_not_found)
        .with_state(state.clone());

    Router::new()
        .nest("/api", api)
        .fallback_service(static_files)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn api_not_found() -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({ "error": "API route not found" })),
    )
        .into_response()
}

async fn health(State(state): State<AppState>) -> Json<ProviderHealth> {
    Json(state.provider.health().await)
}

async fn system() -> Json<HardwareCapabilities> {
    let mut system = System::new();
    system.refresh_memory();
    let total_ram_gib = gibibytes(system.total_memory());
    let available_ram_gib = gibibytes(system.available_memory());
    let logical_cpus = system.cpus().len().max(1) as u32;
    let recommended_tier =
        recommend_tier_for_memory(total_ram_gib, available_ram_gib, logical_cpus);
    let explanation = format!(
        "RAM {total_ram_gib} GiB / CPU {logical_cpus} threads から {} を推奨しました",
        recommended_tier.label()
    );
    Json(HardwareCapabilities {
        total_ram_gib,
        available_ram_gib,
        logical_cpus,
        recommended_tier,
        explanation,
    })
}

fn gibibytes(bytes: u64) -> u32 {
    const GIB: u64 = 1024 * 1024 * 1024;
    u32::try_from(bytes / GIB).unwrap_or(u32::MAX)
}

async fn models(State(state): State<AppState>) -> Json<ModelCatalogResponse> {
    Json(ModelCatalogResponse {
        runtime: "OpenAI-compatible local server",
        active_model: state.assistant.model.clone(),
        endpoint: state.assistant.public_endpoint(),
        profiles: ModelProfile::all().to_vec(),
    })
}

async fn model_health(State(state): State<AppState>) -> Json<ModelHealthResponse> {
    let endpoint = state.assistant.public_endpoint();
    let model = state.assistant.model.clone();
    if model.is_none() {
        return Json(ModelHealthResponse {
            status: "notConfigured".to_owned(),
            reranker_ready: false,
            model,
            endpoint,
            detail: "KANA_AI_MODEL が未設定です".to_owned(),
        });
    }
    if !state.assistant.is_rerank_ready() {
        return Json(ModelHealthResponse {
            status: "disabled".to_owned(),
            reranker_ready: false,
            model,
            endpoint,
            detail: "再順位付けにはループバックの OpenAI 互換エンドポイントが必要です".to_owned(),
        });
    }

    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(900))
        .build();
    let health = match client {
        Ok(client) => {
            let request = client.get(format!("{}/models", state.assistant.base_url));
            match timeout(Duration::from_secs(1), request.send()).await {
                Ok(Ok(response)) if response.status().is_success() => {
                    match response.json::<serde_json::Value>().await {
                        Ok(value) => {
                            let advertised = value
                                .get("data")
                                .and_then(serde_json::Value::as_array)
                                .is_some_and(|models| {
                                    models.iter().any(|entry| {
                                        entry.get("id").and_then(serde_json::Value::as_str)
                                            == state.assistant.model.as_deref()
                                    })
                                });
                            if advertised {
                                ("ready", "モデルの ID を確認しました".to_owned())
                            } else {
                                (
                                    "mismatch",
                                    "サーバーは応答しましたが、設定した model ID がありません"
                                        .to_owned(),
                                )
                            }
                        }
                        Err(error) => (
                            "unavailable",
                            format!("モデル一覧を解析できません: {error}"),
                        ),
                    }
                }
                Ok(Ok(response)) => (
                    "unavailable",
                    format!("モデルサーバーが {} を返しました", response.status()),
                ),
                Ok(Err(error)) => (
                    "unavailable",
                    format!("モデルサーバーに接続できません: {error}"),
                ),
                Err(_) => (
                    "unavailable",
                    "モデルサーバーの応答がタイムアウトしました".to_owned(),
                ),
            }
        }
        Err(error) => (
            "unavailable",
            format!("HTTP クライアントを初期化できません: {error}"),
        ),
    };
    Json(ModelHealthResponse {
        status: health.0.to_owned(),
        reranker_ready: health.0 == "ready",
        model,
        endpoint,
        detail: health.1,
    })
}

async fn config(State(state): State<AppState>) -> Json<ConfigResponse> {
    let endpoint = state.assistant.public_endpoint();
    let ai_runtime = AiRuntimeConfig {
        reranker_ready: state.assistant.is_rerank_ready(),
        endpoint_allowed: state.assistant.is_endpoint_allowed(),
        remote_allowed: state.assistant.allow_remote,
        model: state.assistant.model.clone(),
        endpoint: endpoint.clone(),
        rerank_timeout_millis: reranker::RERANK_TIMEOUT_MILLIS,
        max_rerank_candidates: reranker::MAX_RERANK_CANDIDATES,
        minimum_confidence: reranker::MIN_CONFIDENCE,
    };
    Json(ConfigResponse {
        name: "KanaAI",
        version: env!("CARGO_PKG_VERSION"),
        assistant_configured: state.assistant.is_assistant_ready(),
        assistant_model: state.assistant.model.clone(),
        assistant_endpoint: endpoint,
        model_profiles: ModelProfile::all().to_vec(),
        ai_runtime,
    })
}

async fn convert(
    State(state): State<AppState>,
    Json(request): Json<ConvertRequest>,
) -> Result<Json<ConvertResponse>, ApiError> {
    let ConvertRequest {
        romaji,
        context_before,
        context_after,
        limit,
        ai_mode,
        state: request_state,
    } = request;
    let now = now_millis();
    let limit = limit.min(MAX_CONVERSION_CANDIDATES);
    let context_before = bounded_context(&context_before, true);
    let context_after = bounded_context(&context_after, false);
    let provider_request = ConversionRequest {
        romaji,
        context_before: context_before.clone(),
        context_after,
        limit,
        revision: now,
        convert: true,
    };
    let result = state
        .provider
        .convert(&provider_request)
        .await
        .map_err(ApiError::provider)?;
    let reading = result.reading.clone();
    let focused_candidate_id = result
        .focused_index
        .and_then(|index| result.candidates.get(index).map(|candidate| candidate.id));
    let mut candidates = request_state_personalize(
        &request_state,
        result.candidates,
        &reading,
        &context_before,
        now,
    );
    candidates.truncate(limit);
    let mut focused_index = focused_candidate_id.and_then(|id| {
        candidates
            .iter()
            .position(|candidate| candidate.candidate.id == id)
    });

    let ai = if ai_mode == AiMode::Off {
        None
    } else {
        Some(
            reranker::maybe_rerank(
                &state.assistant,
                reranker::RerankContext {
                    mode: ai_mode,
                    tier: request_state.profile.model_tier,
                    reading: &reading,
                    context_before: &context_before,
                    generation: now,
                },
                &mut candidates,
                &mut focused_index,
            )
            .await,
        )
    };

    Ok(Json(ConvertResponse {
        result: PersonalizedConversionResult {
            provider: result.provider,
            reading: result.reading,
            preedit: result.preedit,
            preedit_segments: result.preedit_segments,
            candidates,
            focused_index,
            consumed: result.consumed,
            elapsed: result.elapsed,
        },
        state: request_state,
        ai,
    }))
}

fn request_state_personalize(
    state: &LearningState,
    candidates: Vec<kanai_core::ConversionCandidate>,
    reading: &str,
    context_before: &str,
    now: u64,
) -> Vec<kanai_core::PersonalizedCandidate> {
    let mut personalized = state.personalize(candidates, reading, context_before, now);
    personalized.sort_by(|left, right| {
        right.score.total_cmp(&left.score).then_with(|| {
            left.candidate
                .provider_rank
                .cmp(&right.candidate.provider_rank)
        })
    });
    personalized
}

async fn commit(
    State(state): State<AppState>,
    Json(request): Json<CommitRequest>,
) -> Result<Json<CommitResponse>, ApiError> {
    if request.expected_text.chars().count() > 256
        || request.reading.chars().count() > 256
        || request.context.chars().count() > 32
    {
        return Err(ApiError::bad_request("commit metadata is too long"));
    }
    let result = state
        .provider
        .commit(request.candidate_id)
        .await
        .map_err(ApiError::provider)?;
    if result.text != request.expected_text {
        return Err(ApiError::bad_request(
            "Mozc commit result no longer matches the selected candidate",
        ));
    }
    let mut next = request.state;
    next.record(
        &request.reading,
        &result.text,
        &context_signature(&request.context),
        now_millis(),
    );
    Ok(Json(CommitResponse {
        result,
        state: next,
    }))
}

async fn reset_state(
    State(_state): State<AppState>,
    Json(_request): Json<StateRequest>,
) -> Json<StateResponse> {
    Json(StateResponse {
        state: LearningState::default(),
    })
}

async fn update_profile(
    State(_state): State<AppState>,
    Json(request): Json<ProfileRequest>,
) -> Json<StateResponse> {
    let mut state = request.state;
    state.profile = request.profile;
    Json(StateResponse { state })
}

async fn add_user_word(
    State(_state): State<AppState>,
    Json(request): Json<UserWordRequest>,
) -> Json<StateResponse> {
    let now = now_millis();
    let mut state = request.state;
    state
        .user_words
        .retain(|word| !(word.reading == request.reading && word.text == request.text));
    state.user_words.push(UserWord {
        id: format!("{}-{now}", state.user_words.len() + 1),
        reading: request.reading,
        text: request.text,
        boost: request.boost.clamp(0.0, 1_000.0),
        created_at: now,
    });
    Json(StateResponse { state })
}

async fn remove_user_word(
    State(_state): State<AppState>,
    Json(request): Json<RemoveUserWordRequest>,
) -> Json<StateResponse> {
    let mut state = request.state;
    state.user_words.retain(|word| word.id != request.id);
    Json(StateResponse { state })
}

async fn assist(
    State(state): State<AppState>,
    Json(request): Json<AssistRequest>,
) -> Result<Json<AssistResponse>, ApiError> {
    if request.text.trim().is_empty() {
        return Err(ApiError::bad_request("文章が空です"));
    }
    if request.text.chars().count() > MAX_ASSIST_CHARS {
        return Err(ApiError::bad_request("AI補助は4,000文字までです"));
    }
    if request.instruction.chars().count() > 256 {
        return Err(ApiError::bad_request("AI補助の指示は256文字までです"));
    }
    let (text, provider, notice) = if state.assistant.is_assistant_ready() {
        match model_assist(&state.assistant, &request).await {
            Ok(response) => response,
            Err(error) => {
                tracing::warn!(%error, "local model assist failed; using local rules");
                (
                    local_assist(&request.instruction, &request.text),
                    "local-rules-fallback".to_owned(),
                    Some(format!(
                        "ローカルAIに接続できませんでした（{error}）。簡易処理へ戻しました。"
                    )),
                )
            }
        }
    } else {
        (
            local_assist(&request.instruction, &request.text),
            "local-rules".to_owned(),
            Some("ローカルAIモデルが未設定のため、ルールベース処理で実行しました".to_owned()),
        )
    };
    Ok(Json(AssistResponse {
        text,
        provider,
        notice,
    }))
}

async fn model_assist(
    config: &AssistantConfig,
    request: &AssistRequest,
) -> Result<(String, String, Option<String>), String> {
    if !config.is_assistant_ready() {
        return Err("AI endpoint is not configured or is disabled".to_owned());
    }
    let api_key = config.api_key.as_ref();
    let model = config
        .model
        .as_ref()
        .ok_or_else(|| "KANA_AI_MODEL is not configured".to_owned())?;
    let style = if request.personalize {
        let terms = request
            .state
            .profile
            .domain_terms
            .iter()
            .filter(|term| !term.trim().is_empty())
            .cloned()
            .collect::<Vec<_>>();
        if terms.is_empty() {
            "語尾を一定にし、簡潔で自然な日本語にする。".to_owned()
        } else {
            format!(
                "専門語（{}）を尊重し、簡潔で自然な日本語にする。",
                terms.join("、")
            )
        }
    } else {
        "指定の形式だけを変え、意味と固有名詞を維持する。".to_owned()
    };
    let payload = serde_json::json!({
        "model": model,
        "temperature": 0.2,
        "messages": [
            {
                "role": "system",
                "content": format!(
                    "あなたは日本語入力 Engines の文章支援です。{style} 結果だけを返し、説明やコードフェンスは付けない。事実を補わず、原文にない情報を作りません。"
                )
            },
            {
                "role": "user",
                "content": format!("指示: {}\n\n本文:\n{}", request.instruction, request.text)
            }
        ]
    });
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| error.to_string())?;
    let request_builder = client.post(format!("{}/chat/completions", config.base_url));
    let request_builder = if let Some(api_key) = api_key {
        request_builder.bearer_auth(api_key)
    } else {
        request_builder
    };
    let response = timeout(
        Duration::from_secs(35),
        request_builder.json(&payload).send(),
    )
    .await
    .map_err(|_| "AI request timed out".to_owned())?
    .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("AI provider returned {}", response.status()));
    }
    let value: serde_json::Value = response.json().await.map_err(|error| error.to_string())?;
    let text = value
        .pointer("/choices/0/message/content")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "AI provider response has no message content".to_owned())?
        .trim()
        .to_owned();
    Ok((text, model.clone(), None))
}

fn local_assist(instruction: &str, text: &str) -> String {
    let trimmed = text.trim();
    if instruction.contains("箇条書き") {
        return trimmed
            .split(['。', '\n'])
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| format!("・{value}"))
            .collect::<Vec<_>>()
            .join("\n");
    }
    if instruction.contains("要約") || instruction.contains("簡潔") {
        return format!(
            "{}。",
            trimmed
                .split_once('。')
                .map_or(trimmed, |(first, _)| first)
                .trim()
        );
    }
    if instruction.contains("丁寧") {
        return format!(
            "{}なお、ご確認いただけますと幸いです。",
            trimmed.trim_end_matches('。')
        );
    }
    format!("整理案:\n{trimmed}")
}

fn bounded_context(context: &str, preceding: bool) -> String {
    const MAX_CONTEXT_CHARS: usize = 32;
    let mut characters = context.chars().collect::<Vec<_>>();
    if characters.len() > MAX_CONTEXT_CHARS {
        if preceding {
            characters = characters.split_off(characters.len() - MAX_CONTEXT_CHARS);
        } else {
            characters.truncate(MAX_CONTEXT_CHARS);
        }
    }
    characters.into_iter().collect()
}

fn context_signature(context: &str) -> String {
    context
        .trim_end()
        .chars()
        .rev()
        .take(12)
        .collect::<String>()
        .chars()
        .rev()
        .collect()
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn provider(error: kanai_core::ProviderError) -> Self {
        let status = match error {
            kanai_core::ProviderError::InvalidRequest(_) => StatusCode::BAD_REQUEST,
            _ => StatusCode::SERVICE_UNAVAILABLE,
        };
        Self {
            status,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({ "error": self.message })),
        )
            .into_response()
    }
}
