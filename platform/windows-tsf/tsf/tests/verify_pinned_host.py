#!/usr/bin/env python3
"""Static acceptance checks for the pinned-upstream Mozc TSF host boundary."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys


def require_markers(path: pathlib.Path, markers: list[str]) -> None:
    text = path.read_text(encoding="utf-8")
    for marker in markers:
        if marker not in text:
            raise AssertionError(f"{path}: missing required host marker {marker!r}")


def run_git(repo: pathlib.Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def verify_git_pin(repo_root: pathlib.Path, expected_commit: str) -> str:
    if not (repo_root / ".git").exists():
        return "not-a-git-worktree"
    try:
        tree_entry = run_git(repo_root, "ls-tree", "HEAD", "third_party/mozc")
    except (FileNotFoundError, subprocess.CalledProcessError):
        return "unavailable"
    fields = tree_entry.split()
    if len(fields) < 3 or fields[0] != "160000":
        raise AssertionError(f"third_party/mozc is not a pinned gitlink: {tree_entry!r}")
    pinned_commit = fields[2]
    if pinned_commit != expected_commit:
        raise AssertionError(
            f"third_party/mozc gitlink is {pinned_commit}, expected {expected_commit}"
        )
    return pinned_commit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=pathlib.Path)
    parser.add_argument(
        "--expected-commit",
        default="13c98988247aa711d99db9e348ec2a597d14b5cd",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    mozc_root = repo_root / "third_party" / "mozc"
    mozc_src = mozc_root / "src"
    tsf_root = repo_root / "platform" / "windows-tsf" / "tsf"
    adapter_root = tsf_root / "host_overlay" / "engine" / "kanai_ai"
    metadata_path = tsf_root / "metadata" / "tsf-integration.json"
    patch_paths = [
        tsf_root / "patches" / "0001-install-kanai-supplemental-model.patch",
        tsf_root / "patches" / "0002-kanai-tsf-identity.patch",
    ]

    if not mozc_src.is_dir():
        raise AssertionError(f"pinned Mozc source is missing: {mozc_src}")

    git_state = verify_git_pin(repo_root, args.expected_commit)

    # Upstream owns the complete TSF shell. These checks intentionally fail if
    # a future pin removes lifecycle, preedit, candidate UI, or registration.
    require_markers(
        mozc_src / "win32" / "tip" / "tip_class_factory.cc",
        ["TipClassFactory::CreateInstance", "LockServer"],
    )
    require_markers(
        mozc_src / "win32" / "tip" / "mozc_tip_main.cc",
        ["DllGetClassObject", "DllCanUnloadNow", "DllMain"],
    )
    require_markers(
        mozc_src / "win32" / "tip" / "tip_text_service.cc",
        [
            "ITfTextInputProcessorEx",
            "ITfKeyEventSink",
            "ITfCompositionSink",
            "CompositionSinkImpl",
            "OnCompositionTerminated",
        ],
    )
    require_markers(
        mozc_src / "win32" / "tip" / "tip_edit_session_impl.cc",
        ["UpdateComposition", "StartComposition", "SetText"],
    )
    require_markers(
        mozc_src / "win32" / "tip" / "tip_ui_handler_conventional.cc",
        ["kCandidateWindow", "candidate_window"],
    )
    require_markers(
        mozc_src / "win32" / "base" / "tsf_profile.cc",
        [
            "10A67BC8-22FA-4A59-90DC-2546652C56BF",
            "186F700C-71CF-43FE-A00E-AACB1D9E6D3D",
            "LANG_JAPANESE",
        ],
    )
    require_markers(
        mozc_src / "win32" / "base" / "tsf_registrar.cc",
        [
            "RegisterCOMServer",
            "RegisterProfiles",
            "AddLanguageProfile",
            "RegisterCategory",
        ],
    )
    require_markers(
        mozc_src / "win32" / "tip" / "BUILD.bazel",
        ['name = "mozc_tip64"', 'platform = "//:windows-x86_64"'],
    )

    # The AI seam is server-side and uses upstream's public extension point.
    require_markers(
        mozc_src / "engine" / "supplemental_model_interface.h",
        [
            "class SupplementalModelInterface",
            "PostCorrect",
            "RescoreResults",
            "Predict",
            "CorrectComposition",
        ],
    )
    require_markers(
        mozc_src / "converter" / "converter.cc",
        ["GetSupplementalModel().PostCorrect"],
    )
    require_markers(
        mozc_src / "prediction" / "dictionary_predictor.cc",
        ["GetSupplementalModel().RescoreResults"],
    )

    broker_root = repo_root / "crates" / "kanai-broker" / "src"
    require_markers(
        broker_root / "frame.rs",
        ['FRAME_MAGIC: [u8; 4] = *b"KBF1"', "DEFAULT_MAX_FRAME_BYTES"],
    )
    require_markers(
        broker_root / "protocol.rs",
        [
            "CandidateRerankRequest",
            "CandidateRerankResponse",
            "RerankCandidates",
            "session_id: SessionId",
            "generation: Generation",
        ],
    )
    require_markers(
        broker_root / "enhancement.rs",
        ["optional executor", "ProviderLocality::Local"],
    )
    require_markers(
        broker_root / "broker.rs",
        ["EnhancementRequiresAsync", "enhancement_token"],
    )

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if metadata["host"]["commit"] != args.expected_commit:
        raise AssertionError("metadata host commit does not match the pinned gitlink")
    if metadata["status"] != "development-seam-not-public-beta":
        raise AssertionError("metadata overstates TSF readiness")
    if metadata["integration"]["patchedUpstreamFiles"] != [
        "third_party/mozc/src/engine/BUILD.bazel",
        "third_party/mozc/src/engine/modules.cc",
        "third_party/mozc/src/win32/base/tsf_profile.cc",
    ]:
        raise AssertionError("metadata patch boundary drifted")
    if metadata["broker"]["frameMagic"] != "KBF1":
        raise AssertionError("native adapter drifted from kanai-broker KBF1")
    if metadata["integration"]["synchronousBrokerCallsFromModel"] is not False:
        raise AssertionError("model must remain off the synchronous broker path")

    require_markers(
        adapter_root / "broker_contract.h",
        ['kBrokerFrameMagic[] = "KBF1"', "EncodeRerankRequestJson"],
    )
    require_markers(
        adapter_root / "pipe_broker_client.cc",
        ["EncodeAuthRequestJson", "BCryptGenRandom", "Authenticate"],
    )
    require_markers(
        adapter_root / "kanai_supplemental_model.cc",
        [
            "sessionId/generation",
            "Deliberately no-op",
            "ApplyRerankToResults",
        ],
    )
    model_text = (adapter_root / "kanai_supplemental_model.cc").read_text(
        encoding="utf-8"
    )
    if "PipeBrokerClient" in model_text or "Rerank(" in model_text:
        raise AssertionError("supplemental model performs synchronous broker I/O")
    if metadata["host"]["type"] != "pinned-upstream-mozc":
        raise AssertionError("adapter is not bound to the pinned upstream host")

    # This is read-only and proves that the only upstream edits are replayable.
    for patch_path in patch_paths:
        subprocess.run(
            ["git", "-C", str(mozc_src), "apply", "--check", str(patch_path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    print(
        json.dumps(
            {
                "status": "pass",
                "pinnedCommit": args.expected_commit,
                "gitPinCheck": git_state,
                "host": "pinned upstream Mozc",
                "publicBeta": False,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, json.JSONDecodeError) as error:
        print(f"verify_pinned_host: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
