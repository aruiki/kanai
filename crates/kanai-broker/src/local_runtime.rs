//! A bounded, pre-integration configuration seam for the pinned local runtime.
//!
//! This module turns the reviewed JSON manifest and staging receipt into a
//! deterministic argument plan for `llama-server`.  It deliberately does not
//! open sockets, read environment variables, inspect the model, hash files, or
//! start a process.  Receipt hashes are compared as metadata only; a platform
//! staging verifier remains responsible for checking the corresponding bytes.
//!
//! The plan contains relative installed paths and non-secret launch settings
//! only.  A later Windows process adapter must resolve the executable, create
//! the per-process API-key file from its own secret store, and pass the
//! resulting argument vector to a process.  The token reference in this
//! module is an opaque adapter handle, never token material.  Callers must
//! supply a relative-path projection of the staging receipt; absolute
//! provenance/source paths are rejected rather than copied into the plan.

use std::fmt;

use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;

/// Maximum size accepted for either JSON document.
pub const MAX_RUNTIME_CONFIG_BYTES: usize = 256 * 1024;
/// Maximum size of an individual JSON text value handled by this seam.
pub const MAX_RUNTIME_TEXT_BYTES: usize = 4096;
/// Maximum size of a relative installed path.
pub const MAX_RUNTIME_PATH_BYTES: usize = 240;
/// Maximum number of runtime entries accepted from a receipt.
pub const MAX_RUNTIME_RECEIPT_ENTRIES: usize = 512;
/// Maximum context window accepted by this first CPU-only launch policy.
pub const MAX_RUNTIME_CONTEXT_SIZE: u32 = 2048;
/// The only host emitted by a plan.
pub const RUNTIME_LOOPBACK_HOST: &str = "127.0.0.1";

/// The schema and status values are deliberately exact so a future manifest
/// cannot silently broaden the launch policy.
pub const PINNED_MANIFEST_SCHEMA: &str = "kanai.ai.runtime.manifest/v1";
pub const PINNED_MANIFEST_STATUS: &str = "pinned-assets-verified-not-staged";
pub const PINNED_RECEIPT_STATUS: &str = "staged-verified-local-ai-runtime";
/// Digest recorded by the reviewed A2-01 staging receipt.  This seam compares
/// that receipt field; it does not hash the manifest bytes or any model bytes.
pub const PINNED_MANIFEST_SHA256: &str =
    "9fab0f800ae6682c081f3f7cdb1f20c01409219fa13de42f5b7c14ff8af83bd3";

pub const PINNED_PRODUCT_ROLE: &str = "optional-local-slow-path";
pub const PINNED_MODEL_ID: &str = "qwen2.5-1.5b-instruct-q4_k_m";
pub const PINNED_MODEL_REPOSITORY: &str = "Qwen/Qwen2.5-1.5B-Instruct-GGUF";
pub const PINNED_MODEL_REVISION: &str = "91cad51170dc346986eccefdc2dd33a9da36ead9";
pub const PINNED_MODEL_FILE: &str = "qwen2.5-1.5b-instruct-q4_k_m.gguf";
pub const PINNED_MODEL_BYTES: u64 = 1_117_320_736;
pub const PINNED_MODEL_SHA256: &str =
    "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e";
pub const PINNED_MODEL_FILE_COMMIT: &str = "dd26da440ef0330c47919d1ecae0966d24022222";
pub const PINNED_MODEL_ROLE: &str = "optional local semantic reranking and explicit slow-path assist; never a synchronous key-path dependency";

pub const PINNED_RUNTIME_ID: &str = "llama.cpp-b11146-win-cpu-x64";
pub const PINNED_RUNTIME_REPOSITORY: &str = "ggml-org/llama.cpp";
pub const PINNED_RUNTIME_RELEASE: &str = "b11146";
pub const PINNED_RUNTIME_REVISION: &str = "7fe450e19305b828c199d602c23a8337aaa1f03b";
pub const PINNED_RUNTIME_LICENSE: &str = "MIT";
pub const PINNED_RUNTIME_ASSET: &str = "llama-b11146-bin-win-cpu-x64.zip";
pub const PINNED_RUNTIME_BYTES: u64 = 18_560_055;
pub const PINNED_RUNTIME_SHA256: &str =
    "14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1";
pub const PINNED_RUNTIME_ROLE: &str = "optional local llama.cpp inference runtime for the model; not a synchronous key-path dependency";
pub const PINNED_RUNTIME_ENTRY_COUNT: u64 = 51;
/// The shipped Rust broker is part of the reviewed AI bundle, so the launch
/// policy pins its bytes as well. A runtime that starts a different executable
/// is not the reviewed build.
pub const PINNED_BROKER_FILE: &str = "kanai-broker.exe";
pub const PINNED_BROKER_BYTES: u64 = 2_817_024;
pub const PINNED_BROKER_SHA256: &str =
    "85f4930d5976b5339de10216d53c20bea4d68d3bae6d25e2668ed24de101dac4";
pub const PINNED_RUNTIME_ENTRY_NAMES_SHA256: &str =
    "68da91a595ea841f87c7f7f34aff23bdf0a9910f129cf0fd3a06264205b61f0c";

const PINNED_MODEL_LICENSE: &str = "Apache-2.0";
const PINNED_MODEL_LICENSE_PATH: &str = "licenses/Qwen-Apache-2.0.txt";
const PINNED_RUNTIME_LICENSE_PATH: &str = "licenses/llama.cpp-MIT.txt";
const PINNED_NOTICE_PATH: &str = "THIRD-PARTY-NOTICES.txt";
const PINNED_NOTICE_BYTES: u64 = 3613;
const PINNED_NOTICE_SHA256: &str =
    "2fa9a4c66b97ca5ae42de7f9372514d866c3e824f4f27ef08ebd07adf76dbae4";
const PINNED_STAGING_MODEL_DIRECTORY: &str = "model";
const PINNED_STAGING_RUNTIME_DIRECTORY: &str = "runtime";
const PINNED_STAGING_LICENSE_DIRECTORY: &str = "licenses";
const PINNED_STAGING_RECEIPT_FILE: &str = "STAGING-RECEIPT.json";
const PINNED_STAGING_LAYOUT: &str = "flat files in declared directories";
const PINNED_STAGING_DELETE_POLICY: &str = "never-delete-caller-paths";
const PINNED_DELETE_POLICY: &str = "no recursive or caller-path deletion";
const PINNED_ARCHIVE_POLICY_STATUS: &str = "inspected-pinned-archive-layout";
const PINNED_ARCHIVE_POLICY_MODE: &str = "exact-allowlist";

/// Typed, non-sensitive failures from manifest/receipt configuration.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RuntimeConfigError {
    #[error("runtime configuration JSON exceeds its bounded input limit")]
    InputTooLarge,
    #[error("runtime configuration JSON is invalid")]
    InvalidJson,
    #[error("runtime configuration document must be a JSON object")]
    InvalidDocument,
    #[error("runtime configuration contains a secret-bearing field")]
    SecretField,
    #[error("runtime configuration text is outside its bounded limit")]
    TextTooLong,
    #[error("runtime configuration is missing required field `{field}`")]
    MissingField { field: &'static str },
    #[error("runtime manifest schema is not approved")]
    InvalidManifestSchema,
    #[error("runtime manifest version is not approved")]
    InvalidManifestVersion,
    #[error("runtime receipt schema is not approved")]
    InvalidReceiptSchema,
    #[error("runtime manifest status is not approved")]
    InvalidManifestStatus,
    #[error("runtime receipt status is missing")]
    MissingReceiptStatus,
    #[error("runtime receipt status is not approved")]
    InvalidReceiptStatus,
    #[error("runtime identity does not match the pinned manifest")]
    IdentityMismatch,
    #[error("runtime artifact hash is invalid or does not match the pinned manifest")]
    HashMismatch,
    #[error("runtime artifact size does not match the pinned manifest")]
    SizeMismatch,
    #[error("runtime path is not a safe relative installed path")]
    UnsafePath,
    #[error("runtime staging layout is not the approved relative layout")]
    LayoutMismatch,
    #[error("runtime launch host must be loopback")]
    InvalidHost,
    #[error("runtime launch port must be nonzero")]
    InvalidPort,
    #[error("runtime launch context is outside the supported bound")]
    InvalidContext,
    #[error("runtime launch parallel setting must be one")]
    InvalidParallel,
    #[error("runtime launch device must be none")]
    InvalidDevice,
    #[error("runtime launch GPU layers must be zero")]
    InvalidGpuLayers,
    #[error("runtime launch UI must be disabled")]
    UiEnabled,
    #[error("runtime token reference is invalid or unbounded")]
    InvalidTokenReference,
}

/// A validated relative path.  The contained value is never an absolute path.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct RelativeInstalledPath(String);

impl RelativeInstalledPath {
    /// Validate and normalize a relative installed path.
    pub fn new(value: impl Into<String>) -> Result<Self, RuntimeConfigError> {
        Ok(Self(normalize_relative_path(&value.into())?))
    }

    /// Borrow the normalized, slash-separated path.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consume the wrapper and return its normalized path.
    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl AsRef<str> for RelativeInstalledPath {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Debug for RelativeInstalledPath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("RelativeInstalledPath")
            .field(&self.0)
            .finish()
    }
}

impl fmt::Display for RelativeInstalledPath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl PartialEq<str> for RelativeInstalledPath {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for RelativeInstalledPath {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

impl PartialEq<String> for RelativeInstalledPath {
    fn eq(&self, other: &String) -> bool {
        &self.0 == other
    }
}

/// An opaque, bounded handle used by a later adapter to locate a per-process
/// key file.  It is not a secret and is never emitted in process arguments.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct TokenReference(String);

impl TokenReference {
    /// Validate an opaque adapter reference, never token material.
    pub fn new(value: impl Into<String>) -> Result<Self, RuntimeConfigError> {
        let value = value.into();
        if value.is_empty()
            || value.len() > 128
            || value.chars().any(|character| {
                character.is_control()
                    || character.is_whitespace()
                    || !character.is_ascii_alphanumeric() && !matches!(character, '-' | '_' | '.')
            })
        {
            return Err(RuntimeConfigError::InvalidTokenReference);
        }
        Ok(Self(value))
    }

    /// Borrow the non-secret adapter reference.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for TokenReference {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("TokenReference(<redacted>)")
    }
}

/// Caller-supplied, bounded launch settings.  There is intentionally no
/// `Default`: a production port is never invented by this module.
#[derive(Clone, PartialEq, Eq)]
pub struct RuntimeLaunchOptions {
    /// Accepted only when it is exactly [`RUNTIME_LOOPBACK_HOST`].
    pub host: String,
    /// A caller-selected nonzero port.
    pub port: u16,
    /// Context window, from 1 through [`MAX_RUNTIME_CONTEXT_SIZE`].
    pub context_size: u32,
    /// Must be one for this single-session policy.
    pub parallel: u32,
    /// Must be the literal `none`.
    pub device: String,
    /// Must be zero for the CPU-only policy.
    pub gpu_layers: u32,
    /// Must be true: the plan always disables the server UI.
    pub no_ui: bool,
    /// Relative path supplied by the platform adapter for its per-process key
    /// file. The file contents are never read here.
    ///
    /// The platform adapter MUST resolve this to an ASCII-safe, access
    /// controlled absolute path before handing it to `llama-server`. A
    /// controlled run showed that b11146 exits before startup when
    /// `--api-key-file` points into a Unicode path, while the same bytes load
    /// and serve a request through an ASCII path. This seam keeps the policy
    /// explicit instead of silently depending on the install root happening
    /// to be ASCII, which is not guaranteed under a localized user profile.
    pub api_key_file: String,
    /// Opaque reference to the adapter's per-process key-file slot.
    pub token_reference: String,
}

impl RuntimeLaunchOptions {
    /// Construct conservative defaults while still requiring a caller port,
    /// key-file path, and token reference.
    #[must_use]
    pub fn new(
        port: u16,
        api_key_file: impl Into<String>,
        token_reference: impl Into<String>,
    ) -> Self {
        Self {
            host: RUNTIME_LOOPBACK_HOST.to_owned(),
            port,
            context_size: MAX_RUNTIME_CONTEXT_SIZE,
            parallel: 1,
            device: "none".to_owned(),
            gpu_layers: 0,
            no_ui: true,
            api_key_file: api_key_file.into(),
            token_reference: token_reference.into(),
        }
    }

    /// Validate all launch settings without touching the filesystem.
    pub fn validate(&self) -> Result<(), RuntimeConfigError> {
        validate_host(&self.host)?;
        if self.port == 0 {
            return Err(RuntimeConfigError::InvalidPort);
        }
        if self.context_size == 0 || self.context_size > MAX_RUNTIME_CONTEXT_SIZE {
            return Err(RuntimeConfigError::InvalidContext);
        }
        if self.parallel != 1 {
            return Err(RuntimeConfigError::InvalidParallel);
        }
        if self.device != "none" {
            return Err(RuntimeConfigError::InvalidDevice);
        }
        if self.gpu_layers != 0 {
            return Err(RuntimeConfigError::InvalidGpuLayers);
        }
        if !self.no_ui {
            return Err(RuntimeConfigError::UiEnabled);
        }
        let _ = RelativeInstalledPath::new(self.api_key_file.clone())?;
        let _ = TokenReference::new(self.token_reference.clone())?;
        Ok(())
    }

    #[must_use]
    pub fn with_host(mut self, host: impl Into<String>) -> Self {
        self.host = host.into();
        self
    }

    #[must_use]
    pub fn with_context_size(mut self, context_size: u32) -> Self {
        self.context_size = context_size;
        self
    }

    #[must_use]
    pub fn with_parallel(mut self, parallel: u32) -> Self {
        self.parallel = parallel;
        self
    }

    #[must_use]
    pub fn with_device(mut self, device: impl Into<String>) -> Self {
        self.device = device.into();
        self
    }

    #[must_use]
    pub fn with_gpu_layers(mut self, gpu_layers: u32) -> Self {
        self.gpu_layers = gpu_layers;
        self
    }

    /// Set the explicit no-UI policy flag.
    #[must_use]
    pub fn with_no_ui(mut self, no_ui: bool) -> Self {
        self.no_ui = no_ui;
        self
    }

    /// Set whether a UI would be enabled; any enabled value is rejected.
    #[must_use]
    pub fn with_ui(mut self, ui_enabled: bool) -> Self {
        self.no_ui = !ui_enabled;
        self
    }
}

impl fmt::Debug for RuntimeLaunchOptions {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RuntimeLaunchOptions")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("context_size", &self.context_size)
            .field("parallel", &self.parallel)
            .field("device", &self.device)
            .field("gpu_layers", &self.gpu_layers)
            .field("no_ui", &self.no_ui)
            .field("api_key_file", &self.api_key_file)
            .field("token_reference", &"<redacted>")
            .finish()
    }
}

/// A deterministic, side-effect-free plan for a future process adapter.
#[derive(Clone, PartialEq, Eq)]
pub struct RuntimeLaunchPlan {
    /// Relative path to the installed model weight.
    pub model_path: RelativeInstalledPath,
    /// Relative path to `llama-server.exe`; the adapter resolves this later.
    pub server_path: RelativeInstalledPath,
    /// Relative path to the per-process API-key file.
    ///
    /// The adapter resolves this against the installed root and is required to
    /// produce an ASCII-safe, access controlled path; see
    /// [`RuntimeLaunchOptions::api_key_file`].
    pub api_key_file_path: RelativeInstalledPath,
    /// Opaque adapter reference, never token material.
    pub api_key_token_reference: TokenReference,
    /// Always exactly `127.0.0.1`.
    pub host: String,
    /// Caller-supplied nonzero port.
    pub port: u16,
    /// Bounded context window.
    pub context_size: u32,
    /// Always one.
    pub parallel: u32,
    /// Always `none`.
    pub device: String,
    /// Always zero.
    pub gpu_layers: u32,
    /// Always true as a policy meaning `--no-ui` is present.
    pub no_ui: bool,
}

impl RuntimeLaunchPlan {
    /// Build a plan from a combined `{ "manifest": ..., "receipt": ... }`
    /// document.  No file is opened and no process is started.
    pub fn from_json(
        document_json: &[u8],
        options: RuntimeLaunchOptions,
    ) -> Result<Self, RuntimeConfigError> {
        build_runtime_launch_plan_from_json(document_json, options)
    }

    /// Build a plan from separate manifest and staging-receipt JSON bytes.
    ///
    /// This validates identity and layout metadata only.  It does not assert
    /// that the runtime dependency closure, model bytes, or token file exist;
    /// those checks belong to the staging/process adapter.
    pub fn from_manifest_and_receipt(
        manifest_json: &[u8],
        receipt_json: &[u8],
        options: RuntimeLaunchOptions,
    ) -> Result<Self, RuntimeConfigError> {
        build_runtime_launch_plan(manifest_json, receipt_json, options)
    }

    /// Alias with a concise name for callers that treat this as configuration.
    pub fn from_manifest_receipt(
        manifest_json: &[u8],
        receipt_json: &[u8],
        options: RuntimeLaunchOptions,
    ) -> Result<Self, RuntimeConfigError> {
        Self::from_manifest_and_receipt(manifest_json, receipt_json, options)
    }

    /// Construct the pure argument vector expected after the future adapter
    /// prepends its executable.  The opaque token reference is deliberately
    /// absent; only the non-secret key-file path is passed to llama-server.
    #[must_use]
    pub fn launch_arguments(&self) -> Vec<String> {
        vec![
            "--model".to_owned(),
            self.model_path.as_str().to_owned(),
            "--ctx-size".to_owned(),
            self.context_size.to_string(),
            "--parallel".to_owned(),
            self.parallel.to_string(),
            "--host".to_owned(),
            RUNTIME_LOOPBACK_HOST.to_owned(),
            "--port".to_owned(),
            self.port.to_string(),
            "--device".to_owned(),
            "none".to_owned(),
            "--gpu-layers".to_owned(),
            "0".to_owned(),
            "--no-ui".to_owned(),
            "--api-key-file".to_owned(),
            self.api_key_file_path.as_str().to_owned(),
        ]
    }

    /// Short alias for [`Self::launch_arguments`].
    #[must_use]
    pub fn arguments(&self) -> Vec<String> {
        self.launch_arguments()
    }

    /// Return a redacted, deterministic command-line representation.  The
    /// command contains no token reference or token value.
    #[must_use]
    pub fn redacted_command_line(&self) -> String {
        self.launch_arguments().join(" ")
    }

    /// Alias emphasizing that this is safe for diagnostics.  It is identical
    /// to the argument vector because the vector never contains a secret.
    #[must_use]
    pub fn redacted_arguments(&self) -> Vec<String> {
        self.launch_arguments()
    }
}

impl fmt::Debug for RuntimeLaunchPlan {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RuntimeLaunchPlan")
            .field("model_path", &self.model_path)
            .field("server_path", &self.server_path)
            .field("api_key_file_path", &self.api_key_file_path)
            .field("api_key_token_reference", &"<redacted>")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("context_size", &self.context_size)
            .field("parallel", &self.parallel)
            .field("device", &self.device)
            .field("gpu_layers", &self.gpu_layers)
            .field("no_ui", &self.no_ui)
            .finish()
    }
}

/// Build a launch plan from separate, bounded manifest and receipt documents.
pub fn build_runtime_launch_plan(
    manifest_json: &[u8],
    receipt_json: &[u8],
    options: RuntimeLaunchOptions,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    let manifest = parse_bounded_value(manifest_json)?;
    let receipt = parse_bounded_value(receipt_json)?;
    build_from_values(manifest, receipt, options)
}

/// Build a launch plan from a combined bounded JSON document.
pub fn build_runtime_launch_plan_from_json(
    document_json: &[u8],
    options: RuntimeLaunchOptions,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    let document = parse_bounded_value(document_json)?;
    let object = document
        .as_object()
        .ok_or(RuntimeConfigError::InvalidDocument)?;
    let manifest = object
        .get("manifest")
        .cloned()
        .ok_or(RuntimeConfigError::MissingField { field: "manifest" })?;
    let receipt = object
        .get("receipt")
        .cloned()
        .ok_or(RuntimeConfigError::MissingField { field: "receipt" })?;
    build_from_values(manifest, receipt, options)
}

/// Explicit alias for callers that prefer a configuration-oriented name.
pub fn runtime_launch_plan_from_manifest_receipt(
    manifest_json: &[u8],
    receipt_json: &[u8],
    options: RuntimeLaunchOptions,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    build_runtime_launch_plan(manifest_json, receipt_json, options)
}

/// Backwards-compatible descriptive alias for the combined-document builder.
pub type RuntimeLaunchConfig = RuntimeLaunchOptions;
/// Alias emphasizing that this module is not a process integration.
pub type LocalRuntimeError = RuntimeConfigError;

fn build_from_values(
    manifest: Value,
    receipt: Value,
    options: RuntimeLaunchOptions,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    build_from_values_with_identity(
        manifest,
        receipt,
        options,
        PINNED_BROKER_BYTES,
        PINNED_BROKER_SHA256,
        PINNED_MANIFEST_SHA256,
    )
}

/// Installed packages bind the running broker externally. Embedding the hash
/// of the executable in that executable would require a hash fixed point.
/// The caller hashes its current executable; packaging binds the same bytes.
pub fn build_installed_runtime_launch_plan(
    manifest_json: &[u8],
    receipt_json: &[u8],
    options: RuntimeLaunchOptions,
    broker_bytes: u64,
    broker_sha256: &str,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    if broker_bytes == 0
        || broker_sha256.len() != 64
        || !broker_sha256.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }
    let manifest = parse_bounded_value(manifest_json)?;
    let receipt = parse_bounded_value(receipt_json)?;
    build_from_values_with_identity(
        manifest,
        receipt,
        options,
        broker_bytes,
        &broker_sha256.to_ascii_lowercase(),
        &sha256_hex(manifest_json),
    )
}

fn build_from_values_with_identity(
    manifest: Value,
    receipt: Value,
    options: RuntimeLaunchOptions,
    broker_bytes: u64,
    broker_sha256: &str,
    manifest_sha256: &str,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    validate_embedded_host(&manifest)?;
    validate_embedded_host(&receipt)?;
    let validated_manifest = validate_manifest(&manifest, broker_bytes, broker_sha256)?;
    validate_receipt(&receipt, &validated_manifest, manifest_sha256)?;
    options.validate()?;

    let model_path = RelativeInstalledPath::new(validated_manifest.model_relative.clone())?;
    let server_path = RelativeInstalledPath::new(validated_manifest.server_relative.clone())?;
    let api_key_file_path = RelativeInstalledPath::new(options.api_key_file.clone())?;
    if api_key_file_path.as_str() == model_path.as_str()
        || api_key_file_path.as_str() == server_path.as_str()
    {
        return Err(RuntimeConfigError::UnsafePath);
    }
    let api_key_token_reference = TokenReference::new(options.token_reference.clone())?;

    Ok(RuntimeLaunchPlan {
        model_path,
        server_path,
        api_key_file_path,
        api_key_token_reference,
        host: RUNTIME_LOOPBACK_HOST.to_owned(),
        port: options.port,
        context_size: options.context_size,
        parallel: 1,
        device: "none".to_owned(),
        gpu_layers: 0,
        no_ui: true,
    })
}

fn parse_bounded_value(bytes: &[u8]) -> Result<Value, RuntimeConfigError> {
    if bytes.len() > MAX_RUNTIME_CONFIG_BYTES {
        return Err(RuntimeConfigError::InputTooLarge);
    }
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| RuntimeConfigError::InvalidJson)?;
    validate_json_tree(&value)?;
    Ok(value)
}

fn validate_json_tree(value: &Value) -> Result<(), RuntimeConfigError> {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if key.len() > MAX_RUNTIME_TEXT_BYTES || key.chars().any(char::is_control) {
                    return Err(RuntimeConfigError::TextTooLong);
                }
                let lower = key.to_ascii_lowercase();
                if lower != "nosecrets" && contains_secret_key(&lower) {
                    return Err(RuntimeConfigError::SecretField);
                }
                validate_json_tree(child)?;
            }
        }
        Value::Array(array) => {
            for child in array {
                validate_json_tree(child)?;
            }
        }
        Value::String(text) if text.len() > MAX_RUNTIME_TEXT_BYTES => {
            return Err(RuntimeConfigError::TextTooLong);
        }
        _ => {}
    }
    Ok(())
}

fn contains_secret_key(lower_key: &str) -> bool {
    lower_key.contains("secret")
        || lower_key.contains("password")
        || lower_key.contains("passwd")
        || lower_key.contains("token")
        || lower_key.contains("credential")
        || lower_key.contains("authorization")
        || lower_key.contains("api_key")
        || lower_key.contains("apikey")
        || lower_key.contains("private_key")
}

fn required<T>(value: Option<T>, field: &'static str) -> Result<T, RuntimeConfigError> {
    value.ok_or(RuntimeConfigError::MissingField { field })
}

fn required_text(value: Option<String>, field: &'static str) -> Result<String, RuntimeConfigError> {
    let value = required(value, field)?;
    if value.len() > MAX_RUNTIME_TEXT_BYTES || value.chars().any(char::is_control) {
        return Err(RuntimeConfigError::TextTooLong);
    }
    Ok(value)
}

fn canonical_sha(value: Option<String>, field: &'static str) -> Result<String, RuntimeConfigError> {
    let value = required_text(value, field)?;
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(RuntimeConfigError::HashMismatch);
    }
    Ok(value.to_ascii_lowercase())
}

fn require_equal(
    value: String,
    expected: &str,
    error: RuntimeConfigError,
) -> Result<(), RuntimeConfigError> {
    if value != expected {
        return Err(error);
    }
    Ok(())
}

fn validate_host(host: &str) -> Result<(), RuntimeConfigError> {
    if host != RUNTIME_LOOPBACK_HOST {
        return Err(RuntimeConfigError::InvalidHost);
    }
    Ok(())
}

fn validate_embedded_host(document: &Value) -> Result<(), RuntimeConfigError> {
    match document {
        Value::Object(object) => {
            for (key, value) in object {
                if key.eq_ignore_ascii_case("host") {
                    let host = value.as_str().ok_or(RuntimeConfigError::InvalidHost)?;
                    validate_host(host)?;
                }
                validate_embedded_host(value)?;
            }
        }
        Value::Array(array) => {
            for value in array {
                validate_embedded_host(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn is_windows_device_segment(segment: &str) -> bool {
    let device_name = segment.split('.').next().unwrap_or(segment).as_bytes();
    matches!(device_name, b"CON" | b"PRN" | b"AUX" | b"NUL")
        || (device_name.len() == 4
            && (device_name[0..3].eq_ignore_ascii_case(b"COM")
                || device_name[0..3].eq_ignore_ascii_case(b"LPT"))
            && device_name[3].is_ascii_digit())
}

fn normalize_relative_path(value: &str) -> Result<String, RuntimeConfigError> {
    if value.is_empty() || value.len() > MAX_RUNTIME_PATH_BYTES {
        return Err(RuntimeConfigError::UnsafePath);
    }
    if value.starts_with('/')
        || value.starts_with('\\')
        || value.as_bytes().get(1).is_some_and(|byte| *byte == b':')
        || value.chars().any(char::is_control)
    {
        return Err(RuntimeConfigError::UnsafePath);
    }
    let normalized = value.replace('\\', "/");
    if normalized.starts_with('/') || normalized.ends_with('/') {
        return Err(RuntimeConfigError::UnsafePath);
    }
    let mut segments = Vec::new();
    for segment in normalized.split('/') {
        if segment.is_empty()
            || segment == "."
            || segment == ".."
            || segment.ends_with('.')
            || segment.ends_with(' ')
            || segment.contains(':')
            || segment.contains('*')
            || segment.contains('?')
            || segment.contains('"')
            || segment.contains('<')
            || segment.contains('>')
            || segment.contains('|')
            || segment.chars().any(char::is_whitespace)
        {
            return Err(RuntimeConfigError::UnsafePath);
        }
        if is_windows_device_segment(segment) {
            return Err(RuntimeConfigError::UnsafePath);
        }
        segments.push(segment);
    }
    if segments.is_empty() {
        return Err(RuntimeConfigError::UnsafePath);
    }
    let result = segments.join("/");
    if result.len() > MAX_RUNTIME_PATH_BYTES {
        return Err(RuntimeConfigError::UnsafePath);
    }
    Ok(result)
}

fn relative_path(value: Option<String>, field: &'static str) -> Result<String, RuntimeConfigError> {
    normalize_relative_path(&required_text(value, field)?)
}

fn optional_relative_path(
    value: Option<String>,
    field: &'static str,
) -> Result<(), RuntimeConfigError> {
    if let Some(value) = value {
        let _ = normalize_relative_path(&value)?;
        let _ = field;
    }
    Ok(())
}

fn join_relative(directory: &str, leaf: &str) -> Result<String, RuntimeConfigError> {
    let directory = normalize_relative_path(directory)?;
    let leaf = normalize_relative_path(leaf)?;
    let result = format!("{directory}/{leaf}");
    normalize_relative_path(&result)
}

struct ValidatedManifest {
    model_relative: String,
    server_relative: String,
    model_bytes: u64,
    model_sha256: String,
    runtime_bytes: u64,
    runtime_sha256: String,
    runtime_entry_names_sha256: String,
}

/// The pinned bundle records what was actually verified locally. These values
/// are deliberately exact: a future manifest that still says the weight was
/// only "pending" or that Windows execution already happened must not silently
/// reuse this launch policy.
const PINNED_UPSTREAM_METADATA_STATUS: &str = "verified-by-coordinator";
const PINNED_BROKER_ARCHITECTURE: &str = "x64";
const PINNED_BROKER_KIND: &str = "Exe";
const PINNED_BROKER_MACHINE: &str = "0x8664";
const PINNED_BROKER_OPTIONAL_MAGIC: &str = "0x020B";

/// The broker is launched by the platform adapter, not by this pure seam, but
/// its identity is part of the reviewed bundle: accepting an arbitrary
/// executable here would let an unreviewed binary drive the AI slow path.
fn validate_broker(
    broker: Option<&BrokerDocument>,
    expected_bytes: u64,
    expected_sha256: &str,
) -> Result<(), RuntimeConfigError> {
    let broker = required(broker.cloned(), "manifest.broker")?;
    require_equal(
        required_text(broker.file_name, "manifest.broker.fileName")?,
        PINNED_BROKER_FILE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(broker.architecture, "manifest.broker.architecture")?,
        PINNED_BROKER_ARCHITECTURE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(broker.kind, "manifest.broker.kind")?,
        PINNED_BROKER_KIND,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(broker.machine, "manifest.broker.machine")?,
        PINNED_BROKER_MACHINE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(
            broker.optional_header_magic,
            "manifest.broker.optionalHeaderMagic",
        )?,
        PINNED_BROKER_OPTIONAL_MAGIC,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if required(broker.bytes, "manifest.broker.bytes")? != expected_bytes {
        return Err(RuntimeConfigError::SizeMismatch);
    }
    require_equal(
        canonical_sha(broker.sha256, "manifest.broker.sha256")?,
        expected_sha256,
        RuntimeConfigError::HashMismatch,
    )?;
    Ok(())
}
const PINNED_MODEL_DIGEST_STATUS: &str = "local-weight-verified";
const PINNED_RUNTIME_DIGEST_STATUS: &str = "local-archive-verified";
const PINNED_LOCAL_DOWNLOAD_STATUS: &str = "performed-and-verified";
const PINNED_CONVERSION_STATUS: &str = "unverified";
const PINNED_WINDOWS_EXECUTION_STATUS: &str = "not-performed";

fn validate_verification(
    verification: Option<&VerificationDocument>,
) -> Result<(), RuntimeConfigError> {
    let verification = required(verification.cloned(), "manifest.verification")?;
    require_equal(
        required_text(
            verification.upstream_metadata,
            "manifest.verification.upstreamMetadata",
        )?,
        PINNED_UPSTREAM_METADATA_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    let digests = required(
        verification.artifact_digests,
        "manifest.verification.artifactDigests",
    )?;
    require_equal(
        required_text(digests.model, "manifest.verification.artifactDigests.model")?,
        PINNED_MODEL_DIGEST_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(
            digests.runtime,
            "manifest.verification.artifactDigests.runtime",
        )?,
        PINNED_RUNTIME_DIGEST_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    let downloads = required(
        verification.local_download,
        "manifest.verification.localDownload",
    )?;
    require_equal(
        required_text(downloads.model, "manifest.verification.localDownload.model")?,
        PINNED_LOCAL_DOWNLOAD_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(
            downloads.runtime,
            "manifest.verification.localDownload.runtime",
        )?,
        PINNED_LOCAL_DOWNLOAD_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(
            verification.conversion_reproducibility,
            "manifest.verification.conversionReproducibility",
        )?,
        PINNED_CONVERSION_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(
            verification.windows_execution,
            "manifest.verification.windowsExecution",
        )?,
        PINNED_WINDOWS_EXECUTION_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if let Some(layout) = verification.archive_entry_layout {
        let layout = required_text(Some(layout), "manifest.verification.archiveEntryLayout")?;
        if !layout.starts_with("inspected-pinned-archive-") {
            return Err(RuntimeConfigError::IdentityMismatch);
        }
    }
    Ok(())
}

fn validate_manifest(
    value: &Value,
    broker_bytes: u64,
    broker_sha256: &str,
) -> Result<ValidatedManifest, RuntimeConfigError> {
    let manifest: ManifestDocument =
        serde_json::from_value(value.clone()).map_err(|_| RuntimeConfigError::InvalidJson)?;

    require_equal(
        required_text(manifest.schema, "manifest.schema")?,
        PINNED_MANIFEST_SCHEMA,
        RuntimeConfigError::InvalidManifestSchema,
    )?;
    if required(manifest.schema_version, "manifest.schemaVersion")? != 1
        || required(manifest.manifest_version, "manifest.manifestVersion")? != 1
    {
        return Err(RuntimeConfigError::InvalidManifestVersion);
    }
    require_equal(
        required_text(manifest.status, "manifest.status")?,
        PINNED_MANIFEST_STATUS,
        RuntimeConfigError::InvalidManifestStatus,
    )?;
    if !required(manifest.no_secrets, "manifest.noSecrets")? {
        return Err(RuntimeConfigError::SecretField);
    }

    let product = required(manifest.product, "manifest.product")?;
    require_equal(
        required_text(product.role, "manifest.product.role")?,
        PINNED_PRODUCT_ROLE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if !required(product.offline_only, "manifest.product.offlineOnly")?
        || required(
            product.network_at_runtime,
            "manifest.product.networkAtRuntime",
        )?
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }

    let platform = required(manifest.platform, "manifest.platform")?;
    if required_text(platform.os, "manifest.platform.os")? != "windows"
        || required_text(platform.architecture, "manifest.platform.architecture")? != "x64"
        || !required(platform.cpu_only, "manifest.platform.cpuOnly")?
        || required(platform.gpu_required, "manifest.platform.gpuRequired")?
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }

    let model = required(manifest.model, "manifest.model")?;
    require_equal(
        required_text(model.id, "manifest.model.id")?,
        PINNED_MODEL_ID,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(model.repository, "manifest.model.repository")?,
        PINNED_MODEL_REPOSITORY,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(model.revision, "manifest.model.revision")?,
        PINNED_MODEL_REVISION,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(model.license, "manifest.model.license")?,
        PINNED_MODEL_LICENSE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(model.expected_role, "manifest.model.expectedRole")?,
        PINNED_MODEL_ROLE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if !required(model.cpu_only, "manifest.model.cpuOnly")?
        || !required(model.offline_only, "manifest.model.offlineOnly")?
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }

    let weight = required(model.weight, "manifest.model.weight")?;
    let model_file = relative_path(weight.file_name, "manifest.model.weight.fileName")?;
    require_equal(
        model_file.clone(),
        PINNED_MODEL_FILE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    let model_bytes = required(weight.bytes, "manifest.model.weight.bytes")?;
    if model_bytes != PINNED_MODEL_BYTES {
        return Err(RuntimeConfigError::SizeMismatch);
    }
    let model_sha256 = canonical_sha(weight.sha256, "manifest.model.weight.sha256")?;
    require_equal(
        model_sha256.clone(),
        PINNED_MODEL_SHA256,
        RuntimeConfigError::HashMismatch,
    )?;
    let lfs_sha256 = canonical_sha(weight.lfs_sha256, "manifest.model.weight.lfsSha256")?;
    if lfs_sha256 != model_sha256 {
        return Err(RuntimeConfigError::HashMismatch);
    }
    require_equal(
        required_text(weight.file_commit, "manifest.model.weight.fileCommit")?,
        PINNED_MODEL_FILE_COMMIT,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if !required(weight.lfs, "manifest.model.weight.lfs")?
        || !required(weight.cpu_only, "manifest.model.weight.cpuOnly")?
        || !required(weight.offline_only, "manifest.model.weight.offlineOnly")?
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }
    if let Some(url) = weight.url {
        require_equal(
            required_text(Some(url), "manifest.model.weight.url")?,
            "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true",
            RuntimeConfigError::IdentityMismatch,
        )?;
    }
    validate_verification(manifest.verification.as_ref())?;
    validate_broker(manifest.broker.as_ref(), broker_bytes, broker_sha256)?;

    let runtime = required(manifest.runtime, "manifest.runtime")?;
    require_equal(
        required_text(runtime.id, "manifest.runtime.id")?,
        PINNED_RUNTIME_ID,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(runtime.repository, "manifest.runtime.repository")?,
        PINNED_RUNTIME_REPOSITORY,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(runtime.release, "manifest.runtime.release")?,
        PINNED_RUNTIME_RELEASE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(runtime.revision, "manifest.runtime.revision")?,
        PINNED_RUNTIME_REVISION,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(runtime.license, "manifest.runtime.license")?,
        PINNED_RUNTIME_LICENSE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(runtime.expected_role, "manifest.runtime.expectedRole")?,
        PINNED_RUNTIME_ROLE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if !required(runtime.cpu_only, "manifest.runtime.cpuOnly")?
        || !required(runtime.offline_only, "manifest.runtime.offlineOnly")?
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }

    let asset = required(runtime.asset, "manifest.runtime.asset")?;
    let runtime_file = relative_path(asset.file_name, "manifest.runtime.asset.fileName")?;
    require_equal(
        runtime_file,
        PINNED_RUNTIME_ASSET,
        RuntimeConfigError::IdentityMismatch,
    )?;
    let runtime_bytes = required(asset.bytes, "manifest.runtime.asset.bytes")?;
    if runtime_bytes != PINNED_RUNTIME_BYTES {
        return Err(RuntimeConfigError::SizeMismatch);
    }
    let runtime_sha256 = canonical_sha(asset.sha256, "manifest.runtime.asset.sha256")?;
    require_equal(
        runtime_sha256.clone(),
        PINNED_RUNTIME_SHA256,
        RuntimeConfigError::HashMismatch,
    )?;
    if !required(asset.cpu_only, "manifest.runtime.asset.cpuOnly")?
        || !required(asset.offline_only, "manifest.runtime.asset.offlineOnly")?
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }

    // The archive entry policy is not optional for the pinned bundle: a
    // manifest that silently drops it would widen what may be staged, so the
    // absence of the block is itself an identity failure.
    let runtime_entry_names =
        validate_runtime_archive(required(runtime.archive, "manifest.runtime.archive")?)?;

    let staging = required(manifest.staging, "manifest.staging")?;
    let model_directory =
        relative_path(staging.model_directory, "manifest.staging.modelDirectory")?;
    let runtime_directory = relative_path(
        staging.runtime_directory,
        "manifest.staging.runtimeDirectory",
    )?;
    let license_directory = relative_path(
        staging.license_directory,
        "manifest.staging.licenseDirectory",
    )?;
    let notice_file = relative_path(staging.notice_file, "manifest.staging.noticeFile")?;
    let receipt_file = relative_path(staging.receipt_file, "manifest.staging.receiptFile")?;
    if model_directory != PINNED_STAGING_MODEL_DIRECTORY
        || runtime_directory != PINNED_STAGING_RUNTIME_DIRECTORY
        || license_directory != PINNED_STAGING_LICENSE_DIRECTORY
        || notice_file != PINNED_NOTICE_PATH
        || receipt_file != PINNED_STAGING_RECEIPT_FILE
    {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if let Some(default_output_directory) = staging.default_output_directory {
        let _ = relative_path(
            Some(default_output_directory),
            "manifest.staging.defaultOutputDirectory",
        )?;
    }
    if let Some(layout) = staging.layout {
        require_equal(
            required_text(Some(layout), "manifest.staging.layout")?,
            PINNED_STAGING_LAYOUT,
            RuntimeConfigError::LayoutMismatch,
        )?;
    }
    if let Some(delete_policy) = staging.delete_policy {
        require_equal(
            required_text(Some(delete_policy), "manifest.staging.deletePolicy")?,
            PINNED_STAGING_DELETE_POLICY,
            RuntimeConfigError::LayoutMismatch,
        )?;
    }

    if let Some(fetch_policy) = manifest.fetch_policy {
        if !required(
            fetch_policy.offline_at_runtime,
            "manifest.fetchPolicy.offlineAtRuntime",
        )? || required(
            fetch_policy.network_implemented,
            "manifest.fetchPolicy.networkImplemented",
        )? {
            return Err(RuntimeConfigError::IdentityMismatch);
        }
        if let Some(schemes) = fetch_policy.allowed_schemes
            && (schemes.len() != 1 || schemes[0] != "https")
        {
            return Err(RuntimeConfigError::IdentityMismatch);
        }
    }

    let model_relative = join_relative(&model_directory, &model_file)?;
    let server_relative = join_relative(&runtime_directory, "llama-server.exe")?;
    let runtime_entry_names_sha256 = entry_names_sha256(&runtime_entry_names)?;
    Ok(ValidatedManifest {
        model_relative,
        server_relative,
        model_bytes,
        model_sha256,
        runtime_bytes,
        runtime_sha256,
        runtime_entry_names_sha256,
    })
}

fn validate_runtime_archive(
    archive: RuntimeArchiveDocument,
) -> Result<Vec<String>, RuntimeConfigError> {
    let policy = required(archive.entry_policy, "manifest.runtime.archive.entryPolicy")?;
    require_equal(
        required_text(policy.status, "manifest.runtime.archive.entryPolicy.status")?,
        PINNED_ARCHIVE_POLICY_STATUS,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(policy.mode, "manifest.runtime.archive.entryPolicy.mode")?,
        PINNED_ARCHIVE_POLICY_MODE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if required(
        policy.entry_count,
        "manifest.runtime.archive.entryPolicy.entryCount",
    )? != PINNED_RUNTIME_ENTRY_COUNT
    {
        return Err(RuntimeConfigError::IdentityMismatch);
    }
    require_equal(
        canonical_sha(
            policy.entry_names_sha256,
            "manifest.runtime.archive.entryPolicy.entryNamesSha256",
        )?,
        PINNED_RUNTIME_ENTRY_NAMES_SHA256,
        RuntimeConfigError::HashMismatch,
    )?;
    if required(
        policy.directory_entries_allowed,
        "manifest.runtime.archive.entryPolicy.directoryEntriesAllowed",
    )? {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    let allowed = required(
        policy.allowed_exact_entries,
        "manifest.runtime.archive.entryPolicy.allowedExactEntries",
    )?;
    if allowed.is_empty() || allowed.len() > MAX_RUNTIME_RECEIPT_ENTRIES {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    let mut seen = Vec::with_capacity(allowed.len());
    for entry in &allowed {
        let entry = normalize_relative_path(&required_text(
            Some(entry.clone()),
            "runtime archive entry",
        )?)?;
        if seen
            .iter()
            .any(|prior: &String| prior.eq_ignore_ascii_case(&entry))
        {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
        seen.push(entry);
    }
    let required_entries = required(
        policy.required_entries,
        "manifest.runtime.archive.entryPolicy.requiredEntries",
    )?;
    let mut required_seen = Vec::with_capacity(required_entries.len());
    for entry in &required_entries {
        let entry = normalize_relative_path(&required_text(
            Some(entry.clone()),
            "manifest.runtime.archive.entryPolicy.requiredEntries",
        )?)?;
        if required_seen
            .iter()
            .any(|prior: &String| prior.eq_ignore_ascii_case(&entry))
        {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
        required_seen.push(entry);
    }
    if !required_seen
        .iter()
        .any(|entry| entry.eq_ignore_ascii_case("llama-server.exe"))
    {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if !allowed
        .iter()
        .any(|entry| entry.eq_ignore_ascii_case("llama-server.exe"))
        || required_seen.iter().any(|required_entry| {
            !allowed
                .iter()
                .any(|entry| entry.eq_ignore_ascii_case(required_entry))
        })
    {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if policy
        .allowed_entry_patterns
        .as_ref()
        .is_some_and(|patterns| patterns.len() != 1 || patterns[0] != "^$")
    {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if let Some(max_entries) = archive.max_entries
        && (max_entries == 0 || max_entries > MAX_RUNTIME_RECEIPT_ENTRIES as u64)
    {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if seen.len() as u64 != PINNED_RUNTIME_ENTRY_COUNT {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    // The allowlist is exact, so its own name digest must equal the pinned
    // runtime layout. This is what stops a manifest from shipping a narrowed
    // or widened entry set under an otherwise unchanged archive digest.
    if entry_names_sha256(&seen)? != PINNED_RUNTIME_ENTRY_NAMES_SHA256 {
        return Err(RuntimeConfigError::HashMismatch);
    }
    Ok(seen)
}

/// Ordinal-sorted, newline-joined entry names with a trailing newline, hashed
/// exactly the way the PowerShell staging receipt and manifest record it.
fn entry_names_sha256(names: &[String]) -> Result<String, RuntimeConfigError> {
    use std::collections::BTreeSet;
    let ordered: BTreeSet<&str> = names.iter().map(String::as_str).collect();
    if ordered.len() != names.len() {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    let mut canonical = String::new();
    for name in ordered {
        canonical.push_str(name);
        canonical.push('\n');
    }
    Ok(sha256_hex(canonical.as_bytes()))
}

/// Dependency-free FIPS 180-4 SHA-256 used only to reproduce the pinned
/// entry-name digest recorded by the PowerShell staging receipt. Keeping it
/// local avoids adding a hashing crate to the broker's sync path; the bytes
/// hashed here are a short, already-bounded entry-name list.
fn sha256_hex(bytes: &[u8]) -> String {
    // Deterministic, dependency-free FIPS 180-4 SHA-256.
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut w = [0u32; 64];
    let mut message = bytes.to_vec();
    let bit_length = (bytes.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_length.to_be_bytes());

    for chunk in message.chunks(64) {
        for (index, word) in chunk.chunks(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..64 {
            let s0 = w[index - 15].rotate_right(7)
                ^ w[index - 15].rotate_right(18)
                ^ (w[index - 15] >> 3);
            let s1 = w[index - 2].rotate_right(17)
                ^ w[index - 2].rotate_right(19)
                ^ (w[index - 2] >> 10);
            w[index] = w[index - 16]
                .wrapping_add(s0)
                .wrapping_add(w[index - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[index])
                .wrapping_add(w[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }

    state.iter().map(|word| format!("{word:08x}")).collect()
}

fn validate_receipt(
    value: &Value,
    manifest: &ValidatedManifest,
    expected_manifest_sha256: &str,
) -> Result<(), RuntimeConfigError> {
    let receipt: ReceiptDocument =
        serde_json::from_value(value.clone()).map_err(|_| RuntimeConfigError::InvalidJson)?;
    if required(receipt.schema_version, "receipt.schemaVersion")? != 1 {
        return Err(RuntimeConfigError::InvalidReceiptSchema);
    }
    let status = receipt
        .status
        .ok_or(RuntimeConfigError::MissingReceiptStatus)?;
    if status.is_empty() {
        return Err(RuntimeConfigError::MissingReceiptStatus);
    }
    if status != PINNED_RECEIPT_STATUS {
        return Err(RuntimeConfigError::InvalidReceiptStatus);
    }

    let receipt_manifest = required(receipt.manifest, "receipt.manifest")?;
    if required(
        receipt_manifest.schema_version,
        "receipt.manifest.schemaVersion",
    )? != 1
    {
        return Err(RuntimeConfigError::InvalidReceiptSchema);
    }
    let manifest_hash = canonical_sha(receipt_manifest.sha256, "receipt.manifest.sha256")?;
    if manifest_hash != expected_manifest_sha256 {
        return Err(RuntimeConfigError::HashMismatch);
    }
    optional_relative_path(receipt_manifest.path, "receipt.manifest.path")?;

    let model = required(receipt.model, "receipt.model")?;
    let staged_model = relative_path(model.staged, "receipt.model.staged")?;
    if staged_model != manifest.model_relative {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if required(model.bytes, "receipt.model.bytes")? != manifest.model_bytes {
        return Err(RuntimeConfigError::SizeMismatch);
    }
    let model_hash = canonical_sha(model.sha256, "receipt.model.sha256")?;
    if model_hash != manifest.model_sha256 {
        return Err(RuntimeConfigError::HashMismatch);
    }
    if let Some(license) = model.license {
        require_equal(
            required_text(Some(license), "receipt.model.license")?,
            PINNED_MODEL_LICENSE,
            RuntimeConfigError::IdentityMismatch,
        )?;
    }
    if let Some(license_path) = model.license_path {
        let license_path = relative_path(Some(license_path), "receipt.model.licensePath")?;
        if license_path != PINNED_MODEL_LICENSE_PATH {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
    }
    optional_relative_path(model.source, "receipt.model.source")?;

    let runtime = required(receipt.runtime, "receipt.runtime")?;
    let staged_directory =
        relative_path(runtime.staged_directory, "receipt.runtime.stagedDirectory")?;
    if staged_directory != PINNED_STAGING_RUNTIME_DIRECTORY {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    if required(runtime.bytes, "receipt.runtime.bytes")? != manifest.runtime_bytes {
        return Err(RuntimeConfigError::SizeMismatch);
    }
    let runtime_hash = canonical_sha(runtime.sha256, "receipt.runtime.sha256")?;
    if runtime_hash != manifest.runtime_sha256 {
        return Err(RuntimeConfigError::HashMismatch);
    }
    require_equal(
        required_text(runtime.release, "receipt.runtime.release")?,
        PINNED_RUNTIME_RELEASE,
        RuntimeConfigError::IdentityMismatch,
    )?;
    require_equal(
        required_text(runtime.revision, "receipt.runtime.revision")?,
        PINNED_RUNTIME_REVISION,
        RuntimeConfigError::IdentityMismatch,
    )?;
    if let Some(license) = runtime.license {
        require_equal(
            required_text(Some(license), "receipt.runtime.license")?,
            PINNED_RUNTIME_LICENSE,
            RuntimeConfigError::IdentityMismatch,
        )?;
    }
    if let Some(license_path) = runtime.license_path {
        let license_path = relative_path(Some(license_path), "receipt.runtime.licensePath")?;
        if license_path != PINNED_RUNTIME_LICENSE_PATH {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
    }
    optional_relative_path(runtime.source, "receipt.runtime.source")?;

    let entries = required(runtime.entries, "receipt.runtime.entries")?;
    if entries.is_empty() || entries.len() > MAX_RUNTIME_RECEIPT_ENTRIES {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    let mut seen = Vec::with_capacity(entries.len());
    let mut has_server = false;
    for entry in entries {
        let entry_path =
            relative_path(entry.relative_path, "receipt.runtime.entries.relativePath")?;
        if !entry_path.starts_with("runtime/") {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
        if seen
            .iter()
            .any(|prior: &String| prior.eq_ignore_ascii_case(&entry_path))
        {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
        seen.push(entry_path.clone());
        if required(entry.bytes, "receipt.runtime.entries.bytes")? == 0 {
            return Err(RuntimeConfigError::SizeMismatch);
        }
        let _ = canonical_sha(entry.sha256, "receipt.runtime.entries.sha256")?;
        if entry_path.eq_ignore_ascii_case(&manifest.server_relative) {
            has_server = true;
        }
    }
    if !has_server {
        return Err(RuntimeConfigError::LayoutMismatch);
    }
    // The staged entry set must reproduce the pinned 51-name layout exactly.
    // Checking only for llama-server.exe would let a truncated or substituted
    // closure satisfy the plan.
    let staged_names: Vec<String> = seen
        .iter()
        .map(|path| path["runtime/".len()..].to_owned())
        .collect();
    if staged_names.len() as u64 != PINNED_RUNTIME_ENTRY_COUNT
        || entry_names_sha256(&staged_names)? != manifest.runtime_entry_names_sha256
    {
        return Err(RuntimeConfigError::LayoutMismatch);
    }

    if required(receipt.network_used, "receipt.networkUsed")? {
        return Err(RuntimeConfigError::IdentityMismatch);
    }
    if let Some(delete_policy) = receipt.delete_policy {
        require_equal(
            required_text(Some(delete_policy), "receipt.deletePolicy")?,
            PINNED_DELETE_POLICY,
            RuntimeConfigError::LayoutMismatch,
        )?;
    }
    if let Some(notice) = receipt.notice {
        let notice_path = relative_path(notice.path, "receipt.notice.path")?;
        if notice_path != PINNED_NOTICE_PATH {
            return Err(RuntimeConfigError::LayoutMismatch);
        }
        if let Some(bytes) = notice.bytes
            && bytes != PINNED_NOTICE_BYTES
        {
            return Err(RuntimeConfigError::SizeMismatch);
        }
        if let Some(hash) = notice.sha256
            && canonical_sha(Some(hash), "receipt.notice.sha256")? != PINNED_NOTICE_SHA256
        {
            return Err(RuntimeConfigError::HashMismatch);
        }
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestDocument {
    schema: Option<String>,
    schema_version: Option<u32>,
    manifest_version: Option<u32>,
    status: Option<String>,
    no_secrets: Option<bool>,
    product: Option<ProductDocument>,
    platform: Option<PlatformDocument>,
    model: Option<ModelDocument>,
    runtime: Option<RuntimeDocument>,
    staging: Option<StagingDocument>,
    fetch_policy: Option<FetchPolicyDocument>,
    verification: Option<VerificationDocument>,
    broker: Option<BrokerDocument>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerDocument {
    file_name: Option<String>,
    architecture: Option<String>,
    bytes: Option<u64>,
    sha256: Option<String>,
    machine: Option<String>,
    optional_header_magic: Option<String>,
    kind: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProductDocument {
    role: Option<String>,
    offline_only: Option<bool>,
    network_at_runtime: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlatformDocument {
    os: Option<String>,
    architecture: Option<String>,
    cpu_only: Option<bool>,
    gpu_required: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelDocument {
    id: Option<String>,
    repository: Option<String>,
    revision: Option<String>,
    license: Option<String>,
    expected_role: Option<String>,
    cpu_only: Option<bool>,
    offline_only: Option<bool>,
    weight: Option<ModelWeightDocument>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelWeightDocument {
    file_name: Option<String>,
    bytes: Option<u64>,
    sha256: Option<String>,
    lfs_sha256: Option<String>,
    file_commit: Option<String>,
    url: Option<String>,
    lfs: Option<bool>,
    cpu_only: Option<bool>,
    offline_only: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeDocument {
    id: Option<String>,
    repository: Option<String>,
    release: Option<String>,
    revision: Option<String>,
    license: Option<String>,
    expected_role: Option<String>,
    cpu_only: Option<bool>,
    offline_only: Option<bool>,
    asset: Option<RuntimeAssetDocument>,
    archive: Option<RuntimeArchiveDocument>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeAssetDocument {
    file_name: Option<String>,
    bytes: Option<u64>,
    sha256: Option<String>,
    cpu_only: Option<bool>,
    offline_only: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeArchiveDocument {
    entry_policy: Option<RuntimeEntryPolicyDocument>,
    max_entries: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerificationDocument {
    upstream_metadata: Option<String>,
    artifact_digests: Option<ArtifactDigestDocument>,
    local_download: Option<LocalDownloadDocument>,
    conversion_reproducibility: Option<String>,
    windows_execution: Option<String>,
    archive_entry_layout: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArtifactDigestDocument {
    model: Option<String>,
    runtime: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocalDownloadDocument {
    model: Option<String>,
    runtime: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeEntryPolicyDocument {
    status: Option<String>,
    mode: Option<String>,
    entry_count: Option<u64>,
    entry_names_sha256: Option<String>,
    allowed_exact_entries: Option<Vec<String>>,
    allowed_entry_patterns: Option<Vec<String>>,
    required_entries: Option<Vec<String>>,
    directory_entries_allowed: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StagingDocument {
    default_output_directory: Option<String>,
    model_directory: Option<String>,
    runtime_directory: Option<String>,
    license_directory: Option<String>,
    notice_file: Option<String>,
    receipt_file: Option<String>,
    layout: Option<String>,
    delete_policy: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FetchPolicyDocument {
    offline_at_runtime: Option<bool>,
    network_implemented: Option<bool>,
    allowed_schemes: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptDocument {
    schema_version: Option<u32>,
    status: Option<String>,
    manifest: Option<ReceiptManifestDocument>,
    model: Option<ReceiptModelDocument>,
    runtime: Option<ReceiptRuntimeDocument>,
    notice: Option<ReceiptNoticeDocument>,
    network_used: Option<bool>,
    delete_policy: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptManifestDocument {
    path: Option<String>,
    sha256: Option<String>,
    schema_version: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptModelDocument {
    source: Option<String>,
    staged: Option<String>,
    bytes: Option<u64>,
    sha256: Option<String>,
    license: Option<String>,
    license_path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptRuntimeDocument {
    source: Option<String>,
    staged_directory: Option<String>,
    bytes: Option<u64>,
    sha256: Option<String>,
    release: Option<String>,
    revision: Option<String>,
    license: Option<String>,
    license_path: Option<String>,
    entries: Option<Vec<ReceiptRuntimeEntryDocument>>,
}

#[derive(Debug, Deserialize)]
struct ReceiptRuntimeEntryDocument {
    #[serde(rename = "RelativePath", alias = "relativePath")]
    relative_path: Option<String>,
    #[serde(rename = "Bytes", alias = "bytes")]
    bytes: Option<u64>,
    #[serde(rename = "Sha256", alias = "sha256")]
    sha256: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptNoticeDocument {
    path: Option<String>,
    bytes: Option<u64>,
    sha256: Option<String>,
}
