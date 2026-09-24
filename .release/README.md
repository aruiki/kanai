# KanaAI release preparation

This directory contains **release planning material only**. KanaAI currently
has no public binary release, official Scoop bucket, installer, native IME, or
code-signing identity. The retired Workbench/CLI package is not a beta. The
first Windows release candidate must be a native TSF TIP based on the pinned
upstream Mozc Windows TIP, followed by real Windows application tests. Nothing
here is an installable manifest as committed.

The full normative release discussion is in
[docs/DISTRIBUTION.md](../docs/DISTRIBUTION.md).

## Planned first Windows release

The first planned Windows channel is a versioned x64 portable ZIP, clearly
marked **unsigned**, from a GitHub Release associated with a protected source
tag. The payload must include the complete tested runtime and launcher, both
project license files, required third-party notices, and user documentation. It
must not include `.env` files, keys, real profiles, histories, dictionaries,
logs, or developer build output.

Planned asset names follow this pattern:

```text
kanai-X.Y.Z-windows-x64-portable.zip
kanai-X.Y.Z-windows-x64-portable.zip.sha256
SHA256SUMS
kanai-X.Y.Z-windows-x64-portable.zip.spdx.json
```

A release must also publish its source SHA, toolchain/build manifest, known
limitations, and a GitHub artifact attestation when supported. Generated
artifacts belong in CI, not in this repository.

## Scoop plan

`scoop-manifest.json.template` is intentionally incomplete. A maintainer may
copy it to a project-controlled, separately reviewed Scoop bucket only after:

1. the exact release ZIP and final bytes exist;
2. its SHA-256 is calculated from those final bytes;
3. the extraction directory and launcher path are confirmed on a clean
   Windows machine;
4. model files, API keys, profiles, notices, and local data are excluded;
5. a second review approves URL, version, hash, architecture, launcher, and
   update policy; and
6. the manifest and ZIP are tested through a clean Scoop install/update/
   uninstall flow.

There is no official `scoop bucket add` command or manifest name to publish
until that review occurs. Do not turn a placeholder into a live manifest.

A Scoop hash proves that the downloaded ZIP matches the reviewed manifest. It
is not an Authenticode signature, publisher identity, malware guarantee, or
SmartScreen/Smart App Control exemption.

## Unsigned release notice

Every future first-signing release must say:

> This Windows build is unsigned. Windows may display a SmartScreen or Smart
> App Control warning. Verify the full SHA-256 digest and GitHub artifact
> attestation before running it. Do not bypass a warning unless you have
> independently established that the artifact is the expected release.

Never use `setup.exe`, a ZIP, a Scoop manifest, an icon, or a friendly filename
as a claim of publisher trust. Never tell users to disable Defender,
SmartScreen, Smart App Control, Gatekeeper, antivirus, or enterprise policy.

## Pre-publication checklist

- [ ] The release is built from a clean, protected tag and exact source commit.
- [ ] The exact `third_party/mozc` gitlink and all applicable notices are recorded.
- [ ] Source manifests, tag, release, and asset versions agree.
- [ ] The root license entry and `LICENSE-MIT`/`LICENSE-APACHE` consistently
  express the reviewed project license without applying it to third-party data.
- [ ] Rust, web, Mozc, package, security, and licensing checks match what
  is claimed.
- [ ] The portable payload is built twice where practical and differences are explained.
- [ ] A clean Windows smoke test covers launch, shutdown, data paths, and
  upgrade expectations.
- [ ] `SHA256SUMS`, the SBOM, build manifest, and artifact attestation are present.
- [ ] The unsigned warning and complete verification steps are visible.
- [ ] The Scoop hash matches the exact ZIP and the manifest is reviewed.
- [ ] A second maintainer approves publication where available.
- [ ] Assets are uploaded once; a bad asset is never silently replaced.
