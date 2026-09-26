#![cfg(windows)]

//! Adapter tests for the pinned Windows AI runtime process.
//!
//! The pure resolution tests need only the reviewed manifest plus a synthetic
//! staging receipt, so they run on any checkout. The one test that starts the
//! real `llama-server` needs the 1.1 GB staged payload, so it is `#[ignore]`d
//! and run explicitly with `--ignored`; an ignored test is not evidence of a
//! pass, and a machine without the payload reports that rather than a
//! fabricated success.

use std::path::{Path, PathBuf};

use kanai_broker::local_runtime::{
    PINNED_MANIFEST_SHA256, PINNED_MODEL_SHA256, PINNED_RUNTIME_SHA256, RuntimeLaunchOptions,
    build_runtime_launch_plan,
};
use kanai_broker::runtime_process_windows::{WindowsProcessError, WindowsRuntimeProcess};
use kanai_broker::runtime_supervisor::{
    RuntimeProcess, RuntimeSupervisor, RuntimeSupervisorConfig, RuntimeSupervisorState,
    TokioRuntimeClock,
};

/// The relative key-file path used by the pure tests.
///
/// It is a caller-supplied option, so every fixture that reaches `from_plan`
/// must stage a file at exactly this path, and every collision test below
/// stages it at its own colliding value instead.
const TEST_KEY_RELATIVE: &str = "ai/runtime/api-key.txt";

/// The relative model path the reviewed manifest pins, duplicated here so a
/// test can stage a placeholder without re-deriving it from the plan.
const TEST_MODEL_RELATIVE: &str = "model/qwen2.5-1.5b-instruct-q4_k_m.gguf";

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is `<repo>/crates/kanai-broker`, so two `parent` steps
    // reach the repository root. A third step would escape the repo and make
    // every stage lookup fail silently.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("repository root")
        .to_path_buf()
}

/// A staging receipt that mirrors the real one: relative identities, the pinned
/// manifest digest, and the full runtime entry closure. The bytes it names are
/// never read by this seam, so the fixture is enough to build a plan.
fn synthetic_receipt() -> Vec<u8> {
    let manifest =
        std::fs::read(repo_root().join("platform/windows-tsf/ai-runtime/manifest-v1.json"))
            .expect("reviewed AI manifest");
    let manifest_value: serde_json::Value =
        serde_json::from_slice(&manifest).expect("manifest parses");
    let allowlist = manifest_value["runtime"]["archive"]["entryPolicy"]["allowedExactEntries"]
        .as_array()
        .expect("pinned allowlist");
    let runtime_entries: Vec<serde_json::Value> = allowlist
        .iter()
        .map(|name| {
            // `serde_json::Value` renders a string *with quotes*, which would
            // smuggle a reserved character into the entry path and make the
            // receipt look like a traversal attempt. Take the raw text.
            let name = name.as_str().expect("allowlist entry is a string");
            serde_json::json!({
                "RelativePath": format!("runtime/{name}"),
                "Bytes": 1_u64,
                "Sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            })
        })
        .collect();
    serde_json::to_vec(&serde_json::json!({
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
            "entries": runtime_entries
        },
        "notice": {
            "path": "THIRD-PARTY-NOTICES.txt",
            "bytes": 3613_u64,
            "sha256": "2fa9a4c66b97ca5ae42de7f9372514d866c3e824f4f27ef08ebd07adf76dbae4"
        },
        "networkUsed": false,
        "deletePolicy": "no recursive or caller-path deletion"
    }))
    .expect("receipt serializes")
}

fn plan_for(options: RuntimeLaunchOptions) -> kanai_broker::local_runtime::RuntimeLaunchPlan {
    build_runtime_launch_plan(
        &std::fs::read(repo_root().join("platform/windows-tsf/ai-runtime/manifest-v1.json"))
            .expect("reviewed AI manifest"),
        &synthetic_receipt(),
        options,
    )
    .expect("the reviewed manifest and receipt must produce a plan")
}

/// Build a plan from an on-disk receipt, used by the real-payload test.
fn plan_from(
    receipt_path: &Path,
    options: RuntimeLaunchOptions,
) -> kanai_broker::local_runtime::RuntimeLaunchPlan {
    build_runtime_launch_plan(
        &std::fs::read(repo_root().join("platform/windows-tsf/ai-runtime/manifest-v1.json"))
            .expect("reviewed AI manifest"),
        &std::fs::read(receipt_path).expect("staging receipt"),
        options,
    )
    .expect("the reviewed manifest and receipt must produce a plan")
}

/// A temporary directory whose path is ASCII.
///
/// The adapter refuses a non-ASCII command line, so on a machine whose `%TEMP%`
/// is not ASCII every test below would fail with a bare
/// `WindowsProcessError::NonAsciiCommandPath` that reads like an adapter bug.
/// Assert the precondition here, with the action that resolves it, instead.
fn ascii_tempdir(label: &str) -> tempfile::TempDir {
    let root = tempfile::tempdir().expect("temporary root");
    assert!(
        root.path().to_str().is_some_and(str::is_ascii),
        "{label}: this test needs an ASCII temporary directory because the adapter refuses a \
         non-ASCII command line. Set TEMP and TMP to an ASCII path such as C:\\Temp, or run the \
         suite under an ASCII account name."
    );
    root
}

/// Stage the three files a plan names under `root`: the runtime executable, the
/// model, and the key file at `key_relative`.
///
/// `from_plan` reads only their metadata, so placeholders are enough to test
/// path resolution and the typed refusals without a 1.1 GB payload.
fn stage_fake_install(root: &Path, key_relative: &str) {
    for relative in [
        "runtime/llama-server.exe",
        TEST_MODEL_RELATIVE,
        key_relative,
    ] {
        let path = root.join(relative);
        std::fs::create_dir_all(path.parent().expect("install subdirectory"))
            .expect("install subdirectory");
        std::fs::write(&path, b"not executed here").expect("placeholder install file");
    }
}

/// Spell an installed-relative path the way the operating system does.
///
/// The plan stores installed paths with forward slashes so the manifest and
/// the staging receipt stay portable, and the adapter normalises every resolved
/// path to native separators. Test expectations therefore have to be built the
/// same way, or they would compare a slash form against a native form and fail
/// for a reason that has nothing to do with what they are checking.
///
/// Only the relative part is rebuilt. Keeping the root exactly as the
/// temporary directory spells it avoids depending on how a `Prefix` component
/// renders, which differs between a drive letter and a verbatim path.
fn native_under(root: &Path, relative: &str) -> String {
    format!(
        "{}{}{}",
        root.display(),
        std::path::MAIN_SEPARATOR,
        relative.replace('/', std::path::MAIN_SEPARATOR_STR)
    )
}

/// A stand-in install root that satisfies every existence check the adapter
/// makes, staged under an ASCII temporary directory.
fn fake_install_root() -> tempfile::TempDir {
    let root = ascii_tempdir("fake_install_root");
    stage_fake_install(root.path(), TEST_KEY_RELATIVE);
    root
}

/// Every resolved installed path must be in the operating system's own
/// separator form.
///
/// The reviewed plan stores installed paths with forward slashes so the
/// manifest and the staging receipt stay portable. Windows accepts a forward
/// slash inside a path, so the runtime still starts, but the resulting path is
/// not equal to the same path the OS reports for a running process. That
/// silently breaks any check against a live process, which is how a real
/// `llama-server.exe` went unnoticed by an earlier version of this suite.
#[test]
fn resolved_installed_paths_use_native_separators() {
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = fake_install_root();
    let process =
        WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path()).expect("adapter builds");

    let executable = process.executable().display().to_string();
    assert!(
        !executable.contains('/'),
        "the executable path must use native separators: {executable}"
    );
    assert_eq!(
        executable,
        native_under(root.path(), "runtime/llama-server.exe"),
        "the executable must resolve to the natively spelled installed path"
    );

    // The command line carries the same two installed paths, so the flag they
    // follow must also be free of forward slashes.
    let rendered = process.redacted_command_line();
    assert!(!rendered.contains('/'), "{rendered}");
    assert!(
        rendered.contains(&format!(
            "--model {}",
            native_under(root.path(), TEST_MODEL_RELATIVE)
        )),
        "{rendered}"
    );
}

#[test]
fn the_adapter_refuses_a_plan_whose_server_is_not_installed() {
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let empty = ascii_tempdir("the_adapter_refuses_a_plan_whose_server_is_not_installed");
    assert_eq!(
        WindowsRuntimeProcess::from_plan(&plan, empty.path(), empty.path())
            .expect_err("a missing runtime executable must be refused"),
        WindowsProcessError::MissingExecutable
    );
}

#[test]
fn the_adapter_refuses_a_plan_whose_model_is_not_installed() {
    // The model is checked before a child exists. Relying on the runtime to
    // reject a missing weight would mean reporting a successful start for a
    // child that exits immediately and is silently restarted.
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = ascii_tempdir("the_adapter_refuses_a_plan_whose_model_is_not_installed");
    stage_fake_install(root.path(), TEST_KEY_RELATIVE);
    std::fs::remove_file(root.path().join(TEST_MODEL_RELATIVE)).expect("model placeholder");
    assert_eq!(
        WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path())
            .expect_err("a missing model must be refused"),
        WindowsProcessError::MissingModel
    );
}

#[test]
fn the_adapter_refuses_a_plan_whose_key_file_is_not_installed() {
    // Whether the pinned runtime would refuse to serve unauthenticated on
    // loopback is not assumed here; the adapter checks instead, so no
    // unauthenticated child can be spawned and reported as a success.
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = ascii_tempdir("the_adapter_refuses_a_plan_whose_key_file_is_not_installed");
    stage_fake_install(root.path(), TEST_KEY_RELATIVE);
    std::fs::remove_file(root.path().join(TEST_KEY_RELATIVE)).expect("key placeholder");
    assert_eq!(
        WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path())
            .expect_err("a missing key file must be refused"),
        WindowsProcessError::MissingKeyFile
    );
}

#[test]
fn the_adapter_refuses_a_non_ascii_command_line() {
    // One controlled run of the pinned b11146 build (revision
    // 7fe450e19305b828c199d602c23a8337aaa1f03b) from a Japanese staging root
    // never reached a serving state, while the same bytes answered a request
    // through an ASCII path, so the adapter fails closed rather than start a
    // child that may not answer. That is one observation of one build, not a
    // measured property of llama.cpp in general.
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = fake_install_root();
    let unicode = root.path().join("日本語");
    stage_fake_install(&unicode, TEST_KEY_RELATIVE);
    assert_eq!(
        WindowsRuntimeProcess::from_plan(&plan, &unicode, &unicode)
            .expect_err("a non-ASCII command line must be refused"),
        WindowsProcessError::NonAsciiCommandPath
    );
}

#[test]
fn the_adapter_never_places_a_token_value_on_the_command_line() {
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = fake_install_root();
    let process =
        WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path()).expect("adapter builds");
    let rendered = process.redacted_command_line();

    // These assertions read the adapter's own resolved command line, not the
    // plan's declared argument list, so a future adapter change is caught here.
    assert!(rendered.contains("--api-key-file"), "{rendered}");
    assert!(rendered.contains("127.0.0.1"), "{rendered}");
    assert!(rendered.contains("--no-ui"), "{rendered}");
    assert!(rendered.contains("--device none"), "{rendered}");
    assert!(rendered.contains("--gpu-layers 0"), "{rendered}");
    assert!(rendered.contains("--parallel 1"), "{rendered}");
    assert!(!rendered.contains("process-slot-1"), "{rendered}");
    assert!(!rendered.contains("Bearer"), "{rendered}");
    assert!(!rendered.contains("--api-key "), "{rendered}");

    // The post-conditions the adapter enforces before any child can exist:
    // each resolved path appears exactly once, and both flags survive. A
    // dropped or duplicated substitution would change these counts.
    let model = native_under(root.path(), TEST_MODEL_RELATIVE);
    let key_file = native_under(root.path(), TEST_KEY_RELATIVE);
    assert!(rendered.contains(&format!("--model {model}")), "{rendered}");
    assert!(
        rendered.ends_with(&format!("--api-key-file {key_file}")),
        "{rendered}"
    );
    assert_eq!(rendered.matches(&model).count(), 1, "{rendered}");
    assert_eq!(rendered.matches(&key_file).count(), 1, "{rendered}");
    assert_eq!(rendered.matches("--model").count(), 1, "{rendered}");
    assert_eq!(rendered.matches("--api-key-file").count(), 1, "{rendered}");
}

#[test]
fn a_key_path_that_collides_with_a_literal_rewrites_only_its_own_element() {
    // `api_key_file` is caller-supplied and validated only as a relative path,
    // so it can equal a literal in the same argument vector. Substituting by
    // value instead of by position would rewrite the wrong element: `127.0.0.1`
    // would also rebind `--host`, `none` would also change `--device`, and
    // `--api-key-file` would erase the flag and leave an unauthenticated
    // loopback server.
    for colliding in ["127.0.0.1", "none", "--api-key-file", "--host", "--port"] {
        let plan = plan_for(RuntimeLaunchOptions::new(
            49_131,
            colliding,
            "process-slot-1",
        ));
        let root = ascii_tempdir("a_key_path_that_collides_with_a_literal");
        stage_fake_install(root.path(), colliding);
        let rendered = WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path())
            .expect("a colliding key path is still resolved by position")
            .redacted_command_line();
        let key_file = root.path().join(colliding).display().to_string();

        // The literal arguments are untouched, and the key path is present
        // exactly once as the value of its own flag.
        assert!(
            rendered.contains("--host 127.0.0.1"),
            "{colliding}: {rendered}"
        );
        assert!(
            rendered.contains("--device none"),
            "{colliding}: {rendered}"
        );
        assert!(rendered.contains("--port 49131"), "{colliding}: {rendered}");
        assert!(
            rendered.contains(&format!(
                "--model {}",
                native_under(root.path(), TEST_MODEL_RELATIVE)
            )),
            "{colliding}: {rendered}"
        );
        assert!(
            rendered.ends_with(&format!("--api-key-file {key_file}")),
            "{colliding}: {rendered}"
        );
        assert_eq!(
            rendered.matches(&key_file).count(),
            1,
            "{colliding}: {rendered}"
        );
    }
}

#[test]
fn the_adapter_debug_output_carries_no_install_path() {
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = fake_install_root();
    let process =
        WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path()).expect("adapter builds");
    let rendered = format!("{process:?}");

    // A derived `Debug` would print absolute paths, which embed the Windows
    // account name. Only the executable's file name and the argument count may
    // appear, so neither a directory separator nor a drive colon can reach a log
    // line.
    assert!(rendered.contains("llama-server.exe"), "{rendered}");
    // Substitution replaces elements in place, so the count is the plan's.
    assert!(
        rendered.contains(&format!(
            "argument_count: {}",
            plan.launch_arguments().len()
        )),
        "{rendered}"
    );
    assert!(!rendered.contains('\\'), "{rendered}");
    assert!(!rendered.contains('/'), "{rendered}");
    // A drive colon can only show up as a bare `X:` token, the way an absolute
    // Windows path starts with one. The two field separators (`executable:` and
    // `argument_count:`) are longer tokens, so this cannot trip on them.
    let drive_colon = rendered.split_whitespace().any(|token| {
        token.len() == 2
            && token.ends_with(':')
            && token.starts_with(|character: char| character.is_ascii_alphabetic())
    });
    assert!(!drive_colon, "{rendered}");
    assert!(
        !rendered.contains(&root.path().display().to_string()),
        "{rendered}"
    );
}

#[test]
fn the_adapter_binds_loopback_and_a_caller_chosen_port() {
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_133,
        TEST_KEY_RELATIVE,
        "process-slot-2",
    ));
    let root = fake_install_root();
    let rendered = WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path())
        .expect("adapter builds")
        .redacted_command_line();
    assert!(rendered.contains("--host 127.0.0.1"), "{rendered}");
    assert!(rendered.contains("--port 49133"), "{rendered}");
    assert!(!rendered.contains("0.0.0.0"), "{rendered}");
}

/// The newest staged AI payload, selected rather than hard-coded.
///
/// The staging directory gains a new name every time the pinned manifest
/// changes, so pinning one here would make this evidence test fail with a
/// "payload is absent" message that reads like a runtime failure instead of a
/// stale path. Directories are ordered by name and the newest one that actually
/// contains the runtime wins, so an older stage is never silently preferred.
fn newest_staged_ai_payload() -> Option<PathBuf> {
    let parent = repo_root().join(".local/ai-runtime");
    let mut stages: Vec<PathBuf> = std::fs::read_dir(&parent)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .filter(|path| path.join("runtime").join("llama-server.exe").is_file())
        .filter(|path| path.join("STAGING-RECEIPT.json").is_file())
        .collect();
    stages.sort();
    stages.pop()
}

#[tokio::test]
#[ignore = "requires the 1.1 GB staged AI payload; run with --ignored"]
async fn the_supervisor_owns_and_terminates_the_real_runtime() {
    let stage = newest_staged_ai_payload().expect(
        "no staged AI payload with a runtime and a staging receipt exists under .local/ai-runtime; \
         run scripts/fetch-stage-pinned-ai-runtime.ps1 -Stage first",
    );
    // The repository lives under a Japanese path and the adapter refuses a
    // non-ASCII command line, so this test reaches the real bytes through a
    // directory junction. A junction is used rather than a symbolic link
    // because it needs no elevation and no developer mode, and the launcher
    // resolves it to the same files, so the evidence is about the same bytes.
    let ascii = ascii_tempdir("the_supervisor_owns_and_terminates_the_real_runtime");
    let install_root = ascii.path().join("kanai-ai");
    // Declared after `ascii` so the junction is detached before the recursive
    // temporary-directory cleanup runs; an attached junction at that point
    // would let the cleanup walk into the staged payload.
    let _junction = make_junction(&install_root, &stage);

    // A real key file is required: the adapter refuses to spawn without one,
    // and this test exists to prove the adapter can own a real child. It is
    // created for this test only, and the guard removes it even when an
    // assertion fails, so no key file is left inside the staged payload.
    let key_relative = "runtime/api-key-loopback-test.txt";
    let _key = ScratchFile::create(
        install_root.join(key_relative),
        b"ephemeral-loopback-test-key",
    );

    let plan = plan_from(
        &stage.join("STAGING-RECEIPT.json"),
        RuntimeLaunchOptions::new(49_131, key_relative, "process-slot-1"),
    );

    let process = WindowsRuntimeProcess::from_plan(&plan, &install_root, &install_root)
        .expect("adapter builds");
    let executable = process.executable().to_path_buf();

    // Baseline first. The probe filters on the exact resolved path and returns
    // pids, so an unrelated `llama-server.exe` cannot satisfy the appeared-wait
    // below: only a pid that is absent from this snapshot can be ours.
    let baseline = runtime_pids(&executable).expect("the baseline pid probe must run");
    let supervisor = RuntimeSupervisor::new(
        std::sync::Arc::new(process),
        std::sync::Arc::new(TokioRuntimeClock),
        RuntimeSupervisorConfig::default(),
    )
    .expect("supervisor config");
    supervisor.start().await.expect("runtime must start");
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Running);

    // A spawn that returns a handle is not proof the real executable is alive,
    // so wait until the operating system reports a *new* pid at the resolved
    // path, and remember which one it is. The probe starts a PowerShell, so
    // the poll interval is a second rather than the tens of milliseconds a
    // `tasklist` call would have allowed.
    let appeared = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let mut owned: Option<u32> = None;
    while std::time::Instant::now() < appeared {
        if let Some(pid) = runtime_pids(&executable)
            .expect("the appeared-wait probe must run")
            .into_iter()
            .find(|pid| !baseline.contains(pid))
        {
            owned = Some(pid);
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    let owned = owned.expect(
        "llama-server.exe never appeared at the resolved path; the pinned runtime did not start",
    );

    // `RuntimeSupervisorConfig::default()` allows three automatic restarts, so a
    // runtime that exits immediately (bad key file, missing DLL, port in use)
    // would be transparently replaced and the appeared-wait above could have
    // been satisfied by any one of those children. Require that the supervisor
    // still owns the child it started and has recorded no failure.
    let snapshot = supervisor.snapshot();
    assert_eq!(
        snapshot.automatic_restarts, 0,
        "the pinned runtime exited and the supervisor restarted it; pid {owned} is not a stable child"
    );
    assert!(
        snapshot.last_error.is_none(),
        "the supervisor recorded a lifecycle failure: {:?}",
        snapshot.last_error
    );
    let before_stop = runtime_pids(&executable).expect("the pre-stop pid probe must run");
    assert!(
        before_stop.contains(&owned),
        "pid {owned} was already gone before the stop; the no-orphan check below would be vacuous"
    );

    supervisor.force_stop().await.expect("force stop");
    // `Idle` proves termination, not graceful drain: this pinned build exposes
    // no cooperative shutdown on a windowless child, so the adapter's graceful
    // stop is a job termination too, and only the disappearance of the process
    // is evidence.
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Idle);

    // The adapter owns a kill-on-close job, so the specific child we observed
    // must be gone rather than orphaned after the supervisor releases it.
    //
    // The probe is required to work *between* the two phases, before the drain
    // loop starts. Without that, a probe that cannot run reports no pids, the
    // loop exits at once, and "pid {owned} is not there any more" is satisfied
    // without anything having been observed at all - the no-orphan assertion is
    // the only real-process evidence this suite has, and it would have been
    // passing on a broken probe.
    assert!(
        runtime_pids(&executable)
            .map(|pids| !pids.contains(&owned))
            .expect("the no-orphan probe must run; otherwise the check below is vacuous"),
        "pid {owned} outlived the supervisor; the job object did not kill it"
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        let pids = runtime_pids(&executable).expect("the drain loop's probe must keep working");
        if !pids.contains(&owned) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    assert!(
        !runtime_pids(&executable)
            .expect("the final pid probe must run")
            .contains(&owned),
        "pid {owned} outlived the supervisor; the job object did not kill it"
    );
}

/// The pid probe has to be able to say "I ran and found nothing".
///
/// The no-orphan assertion in the real-payload test is the only evidence in this
/// suite that a child actually dies, and it consumes this function's answer. If
/// "the probe could not run" and "no such process" both arrive as an empty list,
/// that assertion is satisfied without anything having been observed, so the two
/// answers are separated here, in a test that runs on any checkout, rather than
/// only inside the ignored test that needs the 1.1 GB payload.
#[test]
fn the_pid_probe_reports_a_completed_run_that_found_nothing() {
    // A path no process can have, on a path that does not exist either: the
    // probe must run to completion and report zero pids, which is the answer
    // that means "nothing is running", not "I could not look".
    let missing = Path::new(r"C:\kanai-no-such-install\runtime\llama-server.exe");
    let pids = runtime_pids(missing).expect("the probe must run to completion");
    assert!(
        pids.is_empty(),
        "a path that cannot exist must report no pids: {pids:?}"
    );
}

/// A stage whose "runtime executable" is a real, harmless Windows command that
/// exits at once, so a start can genuinely succeed.
///
/// The refusal under test happens *before* any process is created, so a
/// placeholder file would look identical to a real executable here: `spawn`
/// fails, the adapter reports `Unavailable`, and the assertion would pass for the
/// wrong reason. Copying `cmd.exe` is what makes "the key file was present and
/// the child started" and "the key file was gone and nothing started" two
/// distinguishable outcomes.
fn runnable_stage(key_relative: &str) -> tempfile::TempDir {
    let root = ascii_tempdir("runnable_stage");
    let system = std::env::var("SystemRoot").expect("SystemRoot names the Windows directory");
    let shell = Path::new(&system).join("System32").join("cmd.exe");
    assert!(
        shell.is_file(),
        "this test needs {shell:?} to exist; it is the stand-in runtime executable"
    );
    stage_fake_install(root.path(), key_relative);
    // Copied last: `stage_fake_install` writes a placeholder over the same path,
    // and a placeholder cannot be started, which is the whole point here.
    let executable = root.path().join("runtime").join("llama-server.exe");
    std::fs::copy(&shell, &executable).expect("the stand-in executable is copied");
    root
}

/// A start with no key file must be refused, even though the adapter that plans
/// it checked one.
///
/// The key file is created once, before the supervisor exists, and removed once,
/// when the handle is dropped. Between those two moments the supervisor may start
/// a replacement child, and a child started without the key file is a loopback
/// model server that answers without authentication - so the adapter re-checks
/// the file on every start rather than trusting the check it made when it was
/// built.
#[tokio::test]
async fn a_start_is_refused_when_the_key_file_is_gone() {
    let plan = plan_for(RuntimeLaunchOptions::new(
        49_131,
        TEST_KEY_RELATIVE,
        "process-slot-1",
    ));
    let root = runnable_stage(TEST_KEY_RELATIVE);
    let process = WindowsRuntimeProcess::from_plan(&plan, root.path(), root.path())
        .expect("the adapter builds while the key file exists");
    assert!(process.key_file().is_file());

    // The control. With the key file in place the same adapter starts a real
    // child, so the refusal below is about the key file and not about this
    // harness being unable to start anything.
    let started = process
        .start()
        .await
        .expect("a start with a key file must work");
    started.force_stop().await.expect("stop the control child");

    // The key file goes away, exactly as it does when the broker tears the
    // runtime down. A second start through the very same adapter must be refused.
    std::fs::remove_file(process.key_file()).expect("the key file is removed");
    assert!(
        process.start().await.is_err(),
        "a start without a key file must be refused: it would be a loopback model server with no \
         authentication"
    );
}

/// Create `link` as a directory junction pointing at `target`.
///
/// A junction is used rather than a symbolic link because it needs neither
/// elevation nor developer mode, and `RemoveDirectoryW` detaches it without
/// touching the target. PowerShell is used rather than the `mklink` builtin
/// because `cmd` rewrites a non-ASCII argument through the OEM code page,
/// which mangles exactly the path this test needs to preserve.
///
/// The returned guard detaches the link on drop. That matters: the temporary
/// root that holds this link is removed recursively, and a junction that is
/// still attached at that point would let the cleanup walk into the staged
/// payload. Declaring the guard after the temporary root makes it drop first.
fn make_junction(link: &Path, target: &Path) -> Junction {
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
    Junction {
        link: link.to_path_buf(),
    }
}

/// A directory junction that is detached when it goes out of scope.
struct Junction {
    link: PathBuf,
}

impl Drop for Junction {
    fn drop(&mut self) {
        // `remove_dir` calls RemoveDirectoryW, which removes the reparse point
        // and leaves the target directory untouched. A failure here is reported
        // rather than swallowed: an attached junction would let the temporary
        // directory cleanup walk into the staged payload.
        if let Err(error) = std::fs::remove_dir(&self.link) {
            eprintln!(
                "cleanup: could not detach the junction {}: {error}",
                self.link.display()
            );
        }
    }
}

/// A file created for the duration of one test and removed on drop.
struct ScratchFile {
    path: PathBuf,
}

impl ScratchFile {
    fn create(path: PathBuf, contents: &[u8]) -> Self {
        std::fs::write(&path, contents).expect("scratch file");
        Self { path }
    }
}

impl Drop for ScratchFile {
    fn drop(&mut self) {
        // A leftover key file inside the staged payload would be picked up by
        // the staging and receipt logic, which hashes and packages that
        // directory, so a silent failure here would change a shipped artifact.
        if let Err(error) = std::fs::remove_file(&self.path) {
            eprintln!(
                "cleanup: could not remove the scratch key file {}: {error}",
                self.path.display()
            );
        }
    }
}

/// Render a value as a single-quoted PowerShell string literal.
///
/// The callers pass `to_string_lossy` text, so a path that is not valid Unicode
/// (a lone surrogate) would target a different path than the caller meant. That
/// cannot happen for the paths this file builds: the adapter refuses a
/// non-ASCII or non-Unicode command line, so the resolved path is ASCII by the
/// time it is quoted. The limitation is recorded rather than papered over.
fn quote_for_powershell(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// The pids of every process whose image path is exactly `executable`.
///
/// `tasklist /FI "IMAGENAME eq ..."` is deliberately not used: its filter is a
/// substring match on the image name with no pid, so it cannot tell this test's
/// child from an unrelated `llama-server.exe`, and the no-orphan assertion - the
/// only real-process evidence in this suite - could be satisfied vacuously by a
/// process this test never started. PowerShell is used because it is the only
/// Unicode-safe way to pass the resolved path, and because `$_.Path` is compared
/// for equality rather than by substring.
///
/// `Err` means the probe did not run to completion, which is not the same answer
/// as "no such process". Collapsing the two is what made the drain loop below
/// vacuous: a probe that cannot start returns no pids, the loop exits at once, and
/// the assertion that follows - that the pid is gone - passes. The script prints a
/// completion marker last, so a run that produced no pids is still told apart
/// from a run that produced no answer.
fn runtime_pids(executable: &Path) -> Result<Vec<u32>, String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const COMPLETION: &str = "KANAI-PROBE-COMPLETE";
    let script = format!(
        "Get-Process llama-server -ErrorAction SilentlyContinue \
         | Where-Object {{ $_.Path -eq {} }} \
         | Select-Object -ExpandProperty Id; \
         Write-Output {}",
        quote_for_powershell(&executable.to_string_lossy()),
        quote_for_powershell(COMPLETION)
    );
    let output = std::process::Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .expect("PowerShell lists the runtime processes");
    if !output.status.success() {
        return Err(format!(
            "the pid probe exited with {}",
            output
                .status
                .code()
                .map_or_else(|| "no code".to_owned(), |code| code.to_string())
        ));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut pids = Vec::new();
    let mut completed = false;
    for line in text.lines() {
        if line.trim() == COMPLETION {
            completed = true;
            continue;
        }
        // Anything that is not a pid before the marker is not a process this
        // probe can vouch for, so it is refused rather than skipped.
        if let Ok(pid) = line.trim().parse::<u32>() {
            pids.push(pid);
        } else if !line.trim().is_empty() && !completed {
            return Err("the pid probe produced output it could not parse".to_owned());
        }
    }
    if !completed {
        return Err("the pid probe did not run to completion".to_owned());
    }
    Ok(pids)
}
