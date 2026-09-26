use kanai_broker::{
    MAX_RUNTIME_CONTEXT_SIZE, PINNED_BROKER_BYTES, PINNED_BROKER_FILE, PINNED_BROKER_SHA256,
    PINNED_MANIFEST_SHA256, PINNED_MODEL_FILE, PINNED_MODEL_SHA256,
    PINNED_RUNTIME_ENTRY_NAMES_SHA256, PINNED_RUNTIME_SHA256, RUNTIME_LOOPBACK_HOST,
    RuntimeConfigError, RuntimeLaunchOptions, RuntimeLaunchPlan, build_runtime_launch_plan,
};
use serde_json::{Value, json};

/// Canonical SHA-256 over ordinal-sorted, newline-terminated entry names.
/// Independent reference used to prove the production digest implementation in
/// `local_runtime` matches the PowerShell staging receipt byte for byte.
fn entry_names_sha256(names: &[&str]) -> String {
    let mut ordered: Vec<&str> = names.to_vec();
    ordered.sort_unstable();
    let mut canonical = String::new();
    for name in ordered {
        canonical.push_str(name);
        canonical.push('\n');
    }
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut message = canonical.as_bytes().to_vec();
    let bit_length = (canonical.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_length.to_be_bytes());

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
    for chunk in message.chunks(64) {
        let mut w = [0u32; 64];
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

/// The reviewed b11146 Windows CPU archive layout, exactly as pinned in
/// `platform/windows-tsf/ai-runtime/manifest-v1.json`. Keeping the list in the
/// test (rather than trusting the document under test) is what makes the
/// entry-name digest assertion meaningful.
const RUNTIME_ENTRIES: [&str; 51] = [
    "LICENSE-LLVM-OpenMP",
    "ggml-base.dll",
    "ggml-cpu-alderlake.dll",
    "ggml-cpu-cannonlake.dll",
    "ggml-cpu-cascadelake.dll",
    "ggml-cpu-cooperlake.dll",
    "ggml-cpu-haswell.dll",
    "ggml-cpu-icelake.dll",
    "ggml-cpu-ivybridge.dll",
    "ggml-cpu-piledriver.dll",
    "ggml-cpu-sandybridge.dll",
    "ggml-cpu-sapphirerapids.dll",
    "ggml-cpu-skylakex.dll",
    "ggml-cpu-sse42.dll",
    "ggml-cpu-x64.dll",
    "ggml-cpu-zen4.dll",
    "ggml-rpc-server.exe",
    "ggml-rpc.dll",
    "ggml.dll",
    "libomp.dll",
    "llama-batched-bench-impl.dll",
    "llama-batched-bench.exe",
    "llama-bench-impl.dll",
    "llama-bench.exe",
    "llama-cli-impl.dll",
    "llama-cli.exe",
    "llama-common.dll",
    "llama-completion-impl.dll",
    "llama-completion.exe",
    "llama-fit-params-impl.dll",
    "llama-fit-params.exe",
    "llama-gemma3-cli.exe",
    "llama-gguf-split.exe",
    "llama-imatrix.exe",
    "llama-llava-cli.exe",
    "llama-minicpmv-cli.exe",
    "llama-mtmd-cli.exe",
    "llama-mtmd-debug.exe",
    "llama-perplexity-impl.dll",
    "llama-perplexity.exe",
    "llama-quantize-impl.dll",
    "llama-quantize.exe",
    "llama-qwen2vl-cli.exe",
    "llama-results.exe",
    "llama-server-impl.dll",
    "llama-server.exe",
    "llama-tokenize.exe",
    "llama-tts.exe",
    "llama.dll",
    "llama.exe",
    "mtmd.dll",
];

const RUNTIME_REQUIRED_ENTRIES: [&str; 8] = [
    "LICENSE-LLVM-OpenMP",
    "ggml.dll",
    "libomp.dll",
    "llama-common.dll",
    "llama-server-impl.dll",
    "llama-server.exe",
    "llama.dll",
    "mtmd.dll",
];

/// A receipt that mirrors the real staging layout: relative, forward-slash
/// identities and the full 51-entry runtime closure.
fn receipt_value() -> Value {
    let entries: Vec<Value> = RUNTIME_ENTRIES
        .iter()
        .map(|name| {
            json!({
                "RelativePath": format!("runtime/{name}"),
                "Bytes": 1_u64,
                "Sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            })
        })
        .collect();
    json!({
        "schemaVersion": 1,
        "status": "staged-verified-local-ai-runtime",
        "manifest": {
            "path": "platform/windows-tsf/ai-runtime/manifest-v1.json",
            "sha256": PINNED_MANIFEST_SHA256,
            "schemaVersion": 1
        },
        "model": {
            "source": "inputs/model.gguf",
            "staged": "model/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            "bytes": 1_117_320_736_u64,
            "sha256": PINNED_MODEL_SHA256,
            "license": "Apache-2.0",
            "licensePath": "licenses/Qwen-Apache-2.0.txt"
        },
        "runtime": {
            "source": "inputs/runtime.zip",
            "stagedDirectory": "runtime",
            "bytes": 18_560_055_u64,
            "sha256": PINNED_RUNTIME_SHA256,
            "release": "b11146",
            "revision": "7fe450e19305b828c199d602c23a8337aaa1f03b",
            "license": "MIT",
            "licensePath": "licenses/llama.cpp-MIT.txt",
            "entries": entries
        },
        "notice": {
            "path": "THIRD-PARTY-NOTICES.txt",
            "bytes": 3613_u64,
            "sha256": "2fa9a4c66b97ca5ae42de7f9372514d866c3e824f4f27ef08ebd07adf76dbae4"
        },
        "networkUsed": false,
        "deletePolicy": "no recursive or caller-path deletion"
    })
}

fn manifest_value() -> Value {
    json!({
        "schema": "kanai.ai.runtime.manifest/v1",
        "schemaVersion": 1,
        "manifestVersion": 1,
        "status": "pinned-assets-verified-not-staged",
        "noSecrets": true,
        "product": {
            "role": "optional-local-slow-path",
            "offlineOnly": true,
            "networkAtRuntime": false
        },
        "platform": {
            "os": "windows",
            "architecture": "x64",
            "cpuOnly": true,
            "gpuRequired": false
        },
        "model": {
            "id": "qwen2.5-1.5b-instruct-q4_k_m",
            "repository": "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
            "revision": "91cad51170dc346986eccefdc2dd33a9da36ead9",
            "license": "Apache-2.0",
            "expectedRole": "optional local semantic reranking and explicit slow-path assist; never a synchronous key-path dependency",
            "cpuOnly": true,
            "offlineOnly": true,
            "weight": {
                "fileName": PINNED_MODEL_FILE,
                "bytes": 1_117_320_736_u64,
                "sha256": PINNED_MODEL_SHA256,
                "lfsSha256": PINNED_MODEL_SHA256,
                "fileCommit": "dd26da440ef0330c47919d1ecae0966d24022222",
                "lfs": true,
                "cpuOnly": true,
                "offlineOnly": true
            }
        },
        "runtime": {
            "id": "llama.cpp-b11146-win-cpu-x64",
            "repository": "ggml-org/llama.cpp",
            "release": "b11146",
            "revision": "7fe450e19305b828c199d602c23a8337aaa1f03b",
            "license": "MIT",
            "expectedRole": "optional local llama.cpp inference runtime for the model; not a synchronous key-path dependency",
            "cpuOnly": true,
            "offlineOnly": true,
            "asset": {
                "fileName": "llama-b11146-bin-win-cpu-x64.zip",
                "bytes": 18_560_055_u64,
                "sha256": PINNED_RUNTIME_SHA256,
                "cpuOnly": true,
                "offlineOnly": true
            },
            "archive": {
                "maxEntries": 512,
                "entryPolicy": {
                    "status": "inspected-pinned-archive-layout",
                    "mode": "exact-allowlist",
                    "entryCount": 51,
                    "entryNamesSha256": PINNED_RUNTIME_ENTRY_NAMES_SHA256,
                    "allowedExactEntries": RUNTIME_ENTRIES.to_vec(),
                    "allowedEntryPatterns": ["^$"],
                    "requiredEntries": RUNTIME_REQUIRED_ENTRIES.to_vec(),
                    "directoryEntriesAllowed": false
                }
            }
        },
        "broker": {
            "id": "kanai-broker-x64",
            "fileName": PINNED_BROKER_FILE,
            "role": "optional-local-slow-path broker; the Rust KanaAI broker, not a Mozc payload",
            "architecture": "x64",
            "bytes": PINNED_BROKER_BYTES,
            "sha256": PINNED_BROKER_SHA256,
            "machine": "0x8664",
            "optionalHeaderMagic": "0x020B",
            "kind": "Exe"
        },
        "staging": {
            "defaultOutputDirectory": ".local/ai-runtime/staged",
            "modelDirectory": "model",
            "runtimeDirectory": "runtime",
            "licenseDirectory": "licenses",
            "noticeFile": "THIRD-PARTY-NOTICES.txt",
            "receiptFile": "STAGING-RECEIPT.json",
            "layout": "flat files in declared directories",
            "deletePolicy": "never-delete-caller-paths"
        },
        "verification": {
            "upstreamMetadata": "verified-by-coordinator",
            "artifactDigests": {
                "model": "local-weight-verified",
                "runtime": "local-archive-verified"
            },
            "localDownload": {
                "model": "performed-and-verified",
                "runtime": "performed-and-verified"
            },
            "conversionReproducibility": "unverified",
            "windowsExecution": "not-performed",
            "archiveEntryLayout": "inspected-pinned-archive-2026-09-26"
        }
    })
}

fn options() -> RuntimeLaunchOptions {
    RuntimeLaunchOptions::new(43127, "runtime/api-key-file.txt", "process-slot-1")
}

fn plan(
    manifest: Value,
    receipt: Value,
    options: RuntimeLaunchOptions,
) -> Result<RuntimeLaunchPlan, RuntimeConfigError> {
    build_runtime_launch_plan(
        &serde_json::to_vec(&manifest).expect("manifest serializes"),
        &serde_json::to_vec(&receipt).expect("receipt serializes"),
        options,
    )
}

#[test]
fn independent_reference_reproduces_the_pinned_entry_name_digest() {
    // Guards the production SHA-256 implementation: if the two ever diverge,
    // every real staging receipt would be rejected for the wrong reason.
    assert_eq!(RUNTIME_ENTRIES.len(), 51);
    assert_eq!(
        entry_names_sha256(&RUNTIME_ENTRIES),
        PINNED_RUNTIME_ENTRY_NAMES_SHA256
    );
}

#[test]
fn pinned_manifest_and_receipt_produce_a_deterministic_cpu_plan() {
    let launch_plan =
        plan(manifest_value(), receipt_value(), options()).expect("valid pinned plan");

    assert_eq!(
        launch_plan.model_path.as_str(),
        "model/qwen2.5-1.5b-instruct-q4_k_m.gguf"
    );
    assert_eq!(launch_plan.server_path.as_str(), "runtime/llama-server.exe");
    assert_eq!(
        launch_plan.api_key_file_path.as_str(),
        "runtime/api-key-file.txt"
    );
    assert_eq!(launch_plan.host, RUNTIME_LOOPBACK_HOST);
    assert_eq!(launch_plan.port, 43127);
    assert_eq!(launch_plan.context_size, MAX_RUNTIME_CONTEXT_SIZE);
    assert_eq!(launch_plan.parallel, 1);
    assert_eq!(launch_plan.device, "none");
    assert_eq!(launch_plan.gpu_layers, 0);
    assert!(launch_plan.no_ui);

    let arguments = launch_plan.arguments();
    assert!(
        arguments
            .windows(2)
            .any(|pair| pair == ["--model", "model/qwen2.5-1.5b-instruct-q4_k_m.gguf"])
    );
    assert!(
        arguments
            .windows(2)
            .any(|pair| pair == ["--host", RUNTIME_LOOPBACK_HOST])
    );
    assert!(arguments.windows(2).any(|pair| pair == ["--port", "43127"]));
    assert!(
        arguments
            .windows(2)
            .any(|pair| pair == ["--api-key-file", "runtime/api-key-file.txt"])
    );
    assert!(arguments.iter().any(|argument| argument == "--no-ui"));
    assert_eq!(launch_plan.launch_arguments(), arguments);
}

#[test]
fn exact_identity_and_hash_mismatches_fail_closed() {
    let mut wrong_repository = manifest_value();
    wrong_repository["model"]["repository"] = json!("attacker/model");
    assert_eq!(
        plan(wrong_repository, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::IdentityMismatch
    );

    let mut wrong_schema = manifest_value();
    wrong_schema["schema"] = json!("kanai.ai.runtime.manifest/v2");
    assert_eq!(
        plan(wrong_schema, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::InvalidManifestSchema
    );

    let mut secret_manifest = manifest_value();
    secret_manifest["noSecrets"] = json!(false);
    assert_eq!(
        plan(secret_manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::SecretField
    );

    let mut wrong_model_hash = receipt_value();
    wrong_model_hash["model"]["sha256"] =
        json!("0000000000000000000000000000000000000000000000000000000000000000");
    assert_eq!(
        plan(manifest_value(), wrong_model_hash, options()).unwrap_err(),
        RuntimeConfigError::HashMismatch
    );

    let mut wrong_runtime_hash = receipt_value();
    wrong_runtime_hash["runtime"]["sha256"] =
        json!("1111111111111111111111111111111111111111111111111111111111111111");
    assert_eq!(
        plan(manifest_value(), wrong_runtime_hash, options()).unwrap_err(),
        RuntimeConfigError::HashMismatch
    );

    let mut wrong_manifest_hash = receipt_value();
    wrong_manifest_hash["manifest"]["sha256"] =
        json!("2222222222222222222222222222222222222222222222222222222222222222");
    assert_eq!(
        plan(manifest_value(), wrong_manifest_hash, options()).unwrap_err(),
        RuntimeConfigError::HashMismatch
    );
}

#[test]
fn traversal_absolute_unc_and_drive_paths_are_rejected() {
    let mut traversal = manifest_value();
    traversal["staging"]["modelDirectory"] = json!("../outside");
    assert_eq!(
        plan(traversal, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::UnsafePath
    );

    let mut absolute = receipt_value();
    absolute["model"]["staged"] = json!("C:\\outside\\model.gguf");
    assert_eq!(
        plan(manifest_value(), absolute, options()).unwrap_err(),
        RuntimeConfigError::UnsafePath
    );

    let mut unc = receipt_value();
    unc["runtime"]["entries"][0]["RelativePath"] = json!("\\\\server\\share\\llama-server.exe");
    assert_eq!(
        plan(manifest_value(), unc, options()).unwrap_err(),
        RuntimeConfigError::UnsafePath
    );

    let mut posix_absolute = receipt_value();
    posix_absolute["model"]["staged"] = json!("/etc/model.gguf");
    assert_eq!(
        plan(manifest_value(), posix_absolute, options()).unwrap_err(),
        RuntimeConfigError::UnsafePath
    );

    let mut drive_relative = receipt_value();
    drive_relative["model"]["staged"] = json!("C:model.gguf");
    assert_eq!(
        plan(manifest_value(), drive_relative, options()).unwrap_err(),
        RuntimeConfigError::UnsafePath
    );
}

#[test]
fn remote_host_and_invalid_bounded_launch_settings_are_rejected() {
    for host in ["example.com", "0.0.0.0", "127.0.0.2", "localhost"] {
        assert_eq!(
            plan(manifest_value(), receipt_value(), options().with_host(host)).unwrap_err(),
            RuntimeConfigError::InvalidHost
        );
    }

    assert_eq!(
        plan(
            manifest_value(),
            receipt_value(),
            options().with_context_size(0)
        )
        .unwrap_err(),
        RuntimeConfigError::InvalidContext
    );
    assert_eq!(
        plan(
            manifest_value(),
            receipt_value(),
            options().with_context_size(MAX_RUNTIME_CONTEXT_SIZE + 1)
        )
        .unwrap_err(),
        RuntimeConfigError::InvalidContext
    );
    assert_eq!(
        plan(
            manifest_value(),
            receipt_value(),
            options().with_parallel(2)
        )
        .unwrap_err(),
        RuntimeConfigError::InvalidParallel
    );
    assert_eq!(
        plan(
            manifest_value(),
            receipt_value(),
            options().with_device("cuda")
        )
        .unwrap_err(),
        RuntimeConfigError::InvalidDevice
    );
    let mut ui = options();
    ui.no_ui = false;
    assert_eq!(
        plan(manifest_value(), receipt_value(), ui).unwrap_err(),
        RuntimeConfigError::UiEnabled
    );
    let mut gpu = options();
    gpu.gpu_layers = 1;
    assert_eq!(
        plan(manifest_value(), receipt_value(), gpu).unwrap_err(),
        RuntimeConfigError::InvalidGpuLayers
    );
    let mut zero_port = options();
    zero_port.port = 0;
    assert_eq!(
        plan(manifest_value(), receipt_value(), zero_port).unwrap_err(),
        RuntimeConfigError::InvalidPort
    );
}

#[test]
fn a_reduced_manifest_cannot_broaden_the_approved_runtime_layout() {
    // Dropping the archive policy would silently widen what may be staged.
    let mut manifest = manifest_value();
    manifest["runtime"]
        .as_object_mut()
        .expect("runtime object")
        .remove("archive");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::MissingField {
            field: "manifest.runtime.archive"
        }
    );

    // Narrowing the allowlist must fail the pinned name digest even though the
    // archive digest itself is untouched.
    let mut manifest = manifest_value();
    manifest["runtime"]["archive"]["entryPolicy"]["allowedExactEntries"] =
        json!(["llama-server.exe"]);
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::LayoutMismatch
    );

    // A receipt that stages only llama-server.exe is not a valid closure.
    let mut receipt = receipt_value();
    receipt["runtime"]["entries"] = json!([{
        "RelativePath": "runtime/llama-server.exe",
        "Bytes": 1_u64,
        "Sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }]);
    assert_eq!(
        plan(manifest_value(), receipt, options()).unwrap_err(),
        RuntimeConfigError::LayoutMismatch
    );
}

#[test]
fn unverified_local_state_cannot_reuse_the_approved_launch_policy() {
    // The seam must not treat "metadata only / not yet downloaded" as a
    // verified local bundle.
    let mut manifest = manifest_value();
    manifest["verification"]["artifactDigests"]["model"] = json!("pending");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::IdentityMismatch
    );

    let mut manifest = manifest_value();
    manifest["verification"]["localDownload"]["runtime"] = json!("not-performed");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::IdentityMismatch
    );

    // Windows execution is still unproven; the manifest must keep saying so.
    let mut manifest = manifest_value();
    manifest["verification"]["windowsExecution"] = json!("performed");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::IdentityMismatch
    );

    let mut manifest = manifest_value();
    manifest
        .as_object_mut()
        .expect("manifest object")
        .remove("verification");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::MissingField {
            field: "manifest.verification"
        }
    );
}

#[test]
fn a_receipt_containing_a_host_absolute_path_is_rejected() {
    // Regression: the first real staging receipt serialized a PowerShell
    // FileInfo object graph (PSDrive/Credential/MetadataToken) and host
    // absolute paths. The seam must refuse it instead of planning a launch.
    let mut receipt = receipt_value();
    receipt["manifest"]["path"] = json!(concat!(
        "C:\\Users\\operator\\Documents\\",
        "AI-NihongoIME\\platform\\windows-tsf\\ai-runtime\\manifest-v1.json"
    ));
    assert!(plan(manifest_value(), receipt, options()).is_err());

    let mut receipt = receipt_value();
    receipt["model"]["staged"] =
        json!("C:\\Users\\operator\\.local\\ai-runtime\\staged\\model\\model.gguf");
    assert_eq!(
        plan(manifest_value(), receipt, options()).unwrap_err(),
        RuntimeConfigError::UnsafePath
    );

    let mut receipt = receipt_value();
    let last = receipt["runtime"]["entries"]
        .as_array_mut()
        .expect("entries array")
        .len()
        - 1;
    receipt["runtime"]["entries"][last]["RelativePath"] = json!("runtime\\mtmd.dll");
    // Windows-native separators are still a portable relative identity, not a
    // host path; the seam normalizes them rather than rejecting them.
    let normalized = plan(manifest_value(), receipt, options());
    assert!(
        normalized.is_ok(),
        "a Windows-native separator is a portable relative identity, not a host path: {normalized:?}"
    );
}

#[test]
fn an_unpinned_broker_cannot_enter_the_launch_policy() {
    // The broker is launched by the platform adapter but ships as part of the
    // reviewed bundle, so an unpinned or altered broker must fail closed.
    let mut manifest = manifest_value();
    manifest
        .as_object_mut()
        .expect("manifest object")
        .remove("broker");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::MissingField {
            field: "manifest.broker"
        }
    );

    let mut manifest = manifest_value();
    manifest["broker"]["sha256"] =
        json!("0000000000000000000000000000000000000000000000000000000000000000");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::HashMismatch
    );

    let mut manifest = manifest_value();
    manifest["broker"]["bytes"] = json!(PINNED_BROKER_BYTES + 1);
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::SizeMismatch
    );

    let mut manifest = manifest_value();
    manifest["broker"]["fileName"] = json!("llama-server.exe");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::IdentityMismatch
    );

    let mut manifest = manifest_value();
    manifest["broker"]["kind"] = json!("Dll");
    assert_eq!(
        plan(manifest, receipt_value(), options()).unwrap_err(),
        RuntimeConfigError::IdentityMismatch
    );
}

#[test]
fn missing_receipt_status_is_a_typed_failure() {
    let mut receipt = receipt_value();
    receipt
        .as_object_mut()
        .expect("receipt object")
        .remove("status");
    assert_eq!(
        plan(manifest_value(), receipt, options()).unwrap_err(),
        RuntimeConfigError::MissingReceiptStatus
    );
}

#[test]
fn argument_and_debug_redaction_keep_token_reference_out_of_output() {
    let token_reference = "synthetic-secret-token-value";
    let plan = plan(
        manifest_value(),
        receipt_value(),
        RuntimeLaunchOptions::new(43128, "runtime/per-process.key", token_reference),
    )
    .expect("valid plan");

    let arguments = plan.arguments().join(" ");
    let debug = format!("{plan:?}");
    let options_debug = format!(
        "{:?}",
        RuntimeLaunchOptions::new(43128, "runtime/per-process.key", token_reference)
    );
    assert!(!arguments.contains(token_reference));
    assert!(!debug.contains(token_reference));
    assert!(!options_debug.contains(token_reference));
    assert!(debug.contains("redacted"));
    assert!(arguments.contains("--api-key-file"));
    assert!(!arguments.contains("--api-key "));
}

#[test]
fn combined_document_api_is_also_side_effect_free_and_bounded() {
    let document = json!({ "manifest": manifest_value(), "receipt": receipt_value() });
    let plan = RuntimeLaunchPlan::from_json(
        &serde_json::to_vec(&document).expect("combined document serializes"),
        options(),
    )
    .expect("combined plan");
    assert_eq!(plan.server_path.as_str(), "runtime/llama-server.exe");

    let oversized = vec![b' '; 256 * 1024 + 1];
    assert_eq!(
        RuntimeLaunchPlan::from_json(&oversized, options()).unwrap_err(),
        RuntimeConfigError::InputTooLarge
    );
}
