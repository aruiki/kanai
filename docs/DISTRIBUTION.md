# Distribution and release guide

**Status:** native Windows TSF beta is in development; no public installer,
portable ZIP, Scoop manifest, or signed artifact exists yet.

This document describes a distribution strategy; it does **not** create a ZIP,
`setup.exe`, Scoop manifest, installer script, or other release binary. Those are
build outputs and must be produced by a reviewed release workflow. See
[`OPEN_SOURCE_GUIDELINES.md`](./OPEN_SOURCE_GUIDELINES.md) for project
governance, licensing, security, and signing-secret policy.

The first Windows beta is a native TSF TIP based on the pinned upstream Mozc
Windows TIP. The KanaAI layer adds bounded AI reranking, broker/session
integration, and policy without replacing Mozc's conversion or text-service
lifecycle. A browser Workbench, CLI, HTTP API, or bridge is not a beta artifact
and must not be presented as an IME.

The beta package is unsigned unless a release build is produced with a legitimate
publisher certificate. A `setup.exe` filename is not a trust or SmartScreen
bypass. The complete beta gates are in
[`PRODUCT_RELEASE_CONTRACT.md`](./PRODUCT_RELEASE_CONTRACT.md).


## 1. Decision summary

For the first signing-constrained Windows release:

1. **Primary user path:** a versioned, portable Windows ZIP from a GitHub Release, with a clear `unsigned` label, SHA-256 checksums, an SBOM, and a GitHub artifact attestation.
2. **Preferred package-manager path:** a small, reviewable Scoop manifest in a project-controlled bucket. Scoop verifies the download hash, but the manifest is not a publisher signature and does not make an executable trusted by Windows.
3. **Optional convenience path:** an Inno Setup or NSIS `setup.exe`, built from the same tested payload. It is useful for Start-menu integration and an uninstaller, but it is not required for the first release and remains unsigned until a legitimate signing identity is available.
4. **Future trust path:** Authenticode with a certificate from a trusted provider, Azure Artifact Signing (formerly Azure Trusted Signing), or SignPath. Signing improves identity and integrity checks; it is not a filename trick and does not guarantee that the first SmartScreen prompt disappears.

A release may be useful before it is signed, but it must be honest about its trust level. Never ask users to disable Defender, SmartScreen, Smart App Control, Gatekeeper, or other security controls merely to make an unsigned build run.

## 2. Naming and release identity

Use one canonical product and repository name for release assets. KanaAI is the
canonical name in the current package and Cargo metadata. Older drafts may
mention names such as `nagi-ime` or `kanapilot`; those names must not leak into
release URLs, manifests, or support instructions.

Use a predictable, architecture-specific naming scheme, for example:

```text
<project>-<version>-windows-x64-portable.zip
<project>-<version>-windows-x64-setup.exe       # optional, not the primary path
<project>-<version>-macos-<arch>.zip             # if a macOS build exists
<project>-<version>-linux-<arch>.tar.zst         # source or portable package
```

The version must be the same in the application, source tag, manifest, package metadata, and release notes. Use a version such as `X.Y.Z` without silently changing the artifact name after publication.

## 3. Windows: why `setup.exe` naming does not bypass SmartScreen

`setup.exe` is only a filename. It is not a certificate, a publisher identity, a security boundary, or a SmartScreen allow-list entry. Renaming an unsigned executable to `setup.exe`, `install.exe`, or a similarly familiar name does not make Windows trust it.

SmartScreen and related Windows protections evaluate signals such as:

- whether the executable has a valid Authenticode signature and a trusted certificate chain;
- the reputation of the publisher identity and the particular file hash;
- download context and the mark-of-the-web (MOTW) attached to files downloaded from the Internet; and
- on supported Windows editions, Smart App Control and other code-integrity policies.

A new or unsigned executable can therefore be shown as **Windows protected your PC**, even when it is named `setup.exe`. A ZIP may avoid an installer-specific prompt while it is being downloaded, but an executable extracted from it can still be checked when it is run. A ZIP, a Scoop installation, or a familiar filename is not a security bypass. A self-signed certificate has the same practical problem for ordinary users unless they manually install and trust that certificate, which is not an appropriate public-distribution strategy.

The correct response is to make the artifact verifiable and explain the expected warning. Users who cannot accept an unsigned build should wait for a signed release or build from source. Do not publish instructions that broadly disable security controls, add Defender exclusions, or use execution-policy bypasses.

## 4. Primary unsigned Windows path: portable ZIP

The portable ZIP is the first-release contract because it:

- avoids requiring an installer or administrator privileges;
- makes the exact payload inspectable and easy to reproduce;
- gives Scoop a stable input and lets users choose where to unpack it;
- works with the existing source/build model without pretending that a certificate exists; and
- lets the project publish useful provenance metadata even while signing is unavailable.

The ZIP should contain the complete, tested runtime and launcher, version metadata, the project license and third-party notices, a short `README`, and any required user documentation. It must not contain `.env` files, API keys, local user dictionaries, history, logs, test credentials, or other developer data. Define and test the production runtime and launcher before calling the current web/server tree a desktop release; a `dist/` directory alone is not a Windows application.

The release page must say, in plain language:

> This Windows build is unsigned. Windows may display a SmartScreen or Smart App Control warning. Verify the SHA-256 digest and GitHub artifact attestation before running it. Do not bypass a warning unless you have independently established that the artifact is the expected release.

### Scoop as the preferred package-manager path

Publish a Scoop manifest in a project-controlled bucket, preferably in the same repository under a clearly owned `bucket/` directory. A manifest is a small, reviewable installation recipe; it should be versioned and protected like source code. Do not point it at a floating `latest` URL.

The manifest should include at least:

- the exact release version and release URL;
- the SHA-256 of the downloaded ZIP (lowercase hexadecimal, with no filename or algorithm prefix in the `hash` value);
- the extraction directory and launcher path;
- a short description, homepage, license, and supported architecture;
- a reviewed `checkver`/`autoupdate` policy, if automatic updates are enabled; and
- a `depends` list only for genuinely external prerequisites. Prefer a self-contained portable payload when that is the promise.

The following is a **template only**, not a committed manifest. Replace every placeholder, calculate the hash from the exact published asset, and test it on a clean Windows machine before merging it:

```json
{
  "version": "X.Y.Z",
  "description": "<short description>",
  "homepage": "https://github.com/<owner>/<repo>",
  "license": "MIT",
  "architecture": {
    "64bit": {
      "url": "https://github.com/<owner>/<repo>/releases/download/vX.Y.Z/<project>-X.Y.Z-windows-x64-portable.zip",
      "hash": "<64 lowercase hexadecimal characters>",
      "extract_dir": "<top-level-directory>",
      "bin": "<relative-launcher>",
      "shortcuts": [
        ["<Application name>", "<relative-launcher>"]
      ]
    }
  },
  "checkver": {
    "github": "https://github.com/<owner>/<repo>"
  },
  "autoupdate": {
    "architecture": {
      "64bit": {
        "url": "https://github.com/<owner>/<repo>/releases/download/v$version/<project>-$version-windows-x64-portable.zip"
      }
    },
    "hash": {
      "url": "https://github.com/<owner>/<repo>/releases/download/v$version/<project>-$version-windows-x64-portable.zip.sha256"
    }
  }
}
```

If automatic updates are enabled, publish the referenced per-artifact `.sha256` file in a Scoop-compatible single-digest format and test the `checkver`/autoupdate flow. If that cannot be done reliably, omit `autoupdate` and update the manifest through the normal reviewed release process.

Document the intended commands, for example:

```powershell
scoop bucket add <project> https://github.com/<owner>/<repo>.git
scoop install <project>/<manifest-name>
scoop update <project>/<manifest-name>
```

The bucket and manifest names remain placeholders until a maintainer selects a
project-controlled bucket. A maintainer must review URL, version, hash,
extraction path, and launcher path as a single change. The manifest's hash
protects download integrity; it does not authenticate the maintainer, replace
Authenticode, or suppress SmartScreen when the launcher is eventually run.
Scoop users should still follow the verification guidance below.

## 5. Optional Inno Setup or NSIS `setup.exe`

An installer is an optional user-experience improvement, not the trust foundation. If there is demonstrated demand for shortcuts, Start-menu registration, an uninstaller, or a conventional install path, choose **one** of these tools and keep its script in source control:

- **Inno Setup:** suitable for a conventional Windows installer with a scripted wizard, per-user install, uninstall section, and pinned compiler version.
- **NSIS:** suitable for a smaller installer with a compact script, per-user install, uninstaller, and pinned compiler version.

The installer definition must be reviewed like code. At minimum, require x64 as appropriate, avoid an unnecessary administrator requirement, install only the tested payload, provide a complete uninstaller, use stable paths, include licenses/notices, and avoid an unreviewed auto-updater or network download during installation. The same source commit and SBOM must be used for the ZIP and any optional installer.

An unsigned `setup.exe` will still be an unsigned executable. Label it as such, publish its checksum and attestation, and do not imply that Inno Setup, NSIS, a particular filename, or a bundled icon establishes trust. Do not commit generated installer files; generate them only in the release job.

## 6. Artifact contract

A release should have a small, explicit set of assets:

| Asset | First unsigned release | Purpose |
| --- | --- | --- |
| Source archive for the exact tag | Required | Rebuild and license review; include the pinned third-party state |
| `<project>-...-windows-x64-portable.zip` | Required | Primary Windows distribution |
| `SHA256SUMS` and/or per-file `.sha256` | Required | Integrity verification |
| SPDX or CycloneDX SBOM | Required | Dependency and license inventory |
| GitHub artifact attestation | Required when the repository supports it | Build provenance and workflow identity |
| Project-owned Scoop manifest | Required for the primary package-manager path | Reproducible, hash-pinned installation recipe |
| `<project>-...-windows-x64-setup.exe` | Optional | Installer UX; not a SmartScreen workaround |
| Release provenance/build manifest | Required | Source SHA, toolchain, flags, dependency state, and artifact map |

Do not replace an asset in place after publication. If an artifact is wrong, publish a new version or a clearly marked security revision, revoke the old download where possible, and preserve the audit trail.

## 7. Reproducible build procedure

“Reproducible” means that a clean, pinned build of the same source and toolchain produces the same bytes, or that any unavoidable non-determinism is explicitly measured and explained. The following procedure is the minimum for a release:

1. **Use a clean, tagged checkout.** Start from an annotated/protected `vX.Y.Z` tag or an exact commit SHA. Verify that the working tree is clean and that all submodules, including `third_party/mozc`, are initialized at the recorded gitlink commits. A plain `git archive` does not automatically include submodule contents; use a documented source-bundle process that includes or precisely identifies every required submodule.
2. **Lock inputs.** Use committed lockfiles and exact toolchain versions. For the web portion, use `npm ci`, not an unlocked `npm install`; for Rust, use `--locked`; pin Node, Rust, and packaging-tool versions in the release environment. Do not silently update a dependency during a release.
3. **Restrict the build.** Use a clean Windows runner or a pinned build image, a fixed locale/time zone, and a declared dependency cache. Fail if the checkout, submodule state, lockfile, or toolchain differs from the release manifest.
4. **Normalize inputs.** Set `SOURCE_DATE_EPOCH` from the tagged commit timestamp, use UTC and a fixed locale, normalize line endings and file permissions, and remove machine-specific paths and secrets. A representative shell setup is:

   ```sh
   export SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$TAG")"
   export TZ=UTC
   export LC_ALL=C
   ```

5. **Build and test the staged payload.** Run the project’s checks (for the current web tree, `npm ci` followed by `npm run check`) and the native/test targets that actually exist in the release branch. Run a clean Windows smoke test, including install/extract, launch, shutdown, data-directory behavior, and upgrade/rollback expectations.
6. **Package deterministically.** Use a pinned ZIP tool or a reviewed packaging script with fixed file ordering, timestamps, permissions, compression settings, and root directory. Do not assume a generic PowerShell ZIP command is deterministic merely because the contents are the same.
7. **Build twice independently.** Compare SHA-256 values of the unsigned payload from two clean builds. Investigate every difference. If an installer tool embeds a timestamp or other variable, record that limitation and test whether it can be normalized **before** any signature is applied.
8. **Record provenance.** Save a machine-readable build manifest containing the source/tag SHA, submodule SHAs, tool versions, compiler/linker flags, target architecture, dependency lockfile digests, build image digest, `SOURCE_DATE_EPOCH`, and the artifact-to-source mapping.
9. **Sign last, if signing is later enabled.** Reproducibility applies most cleanly to the unsigned build. A signature and RFC 3161 timestamp can change the final bytes, so compute the published checksum and attestation for the exact final, signed artifact.

Do not call a build reproducible merely because it came from GitHub Actions. The claim must be supported by pinned inputs and a repeatable comparison procedure.

## 8. Checksums, SBOM, and GitHub artifact attestations

### SHA-256 checksums

Publish SHA-256 for every user-downloadable artifact, including the portable ZIP and any optional `setup.exe`. Keep a canonical `SHA256SUMS` file with relative artifact names and deterministic ordering. Do not use MD5 or SHA-1 for release integrity.

On a Unix-like system:

```sh
sha256sum <artifact-1> <artifact-2> > SHA256SUMS
sha256sum --check SHA256SUMS
```

On Windows PowerShell:

```powershell
Get-FileHash -Path .\artifact.zip -Algorithm SHA256
(Get-FileHash -Path .\artifact.zip -Algorithm SHA256).Hash.ToLowerInvariant()
```

The second form is a comparison aid; use the real filename and compare the complete digest, not a prefix. A checksum detects accidental corruption and some tampering, but a checksum downloaded beside a replaced binary proves nothing by itself; protect the release account and corroborate it with provenance or a signature.

Publish checksums through HTTPS from the canonical release, and later sign or attest the checksum/manifest as well as the payload. A Scoop manifest must contain the hash of the exact ZIP it downloads, not the hash of an extracted directory or a different architecture.

### SBOM

Generate a pinned SPDX 2.3 JSON or CycloneDX JSON SBOM for every platform/package variant, using a pinned generator such as Syft or a CycloneDX tool and recording its version. Include runtime and build dependencies as appropriate, including:

- Node packages and the exact Node runtime assumptions;
- Rust crates and native libraries;
- bundled Mozc code or other third-party components;
- data/model files and their source/license information;
- package URLs (`purl`), versions, hashes, scope, supplier/source, and license identifiers; and
- the tool or process used to generate the SBOM.

Review the SBOM for secrets and user data before publishing. Validate its schema, retain it with the release, and include it in the attestation. An SBOM improves visibility and license/compliance work; it is not a claim that the software is vulnerability-free.

### GitHub artifact attestations

GitHub artifact attestations are keyless, signed provenance records generated by GitHub Actions using short-lived Sigstore credentials. They bind an artifact digest to the workflow, repository, commit, and build context. They are valuable even while Windows binaries are unsigned.

A conceptual release step (after building and calculating the checksum file) is:

```yaml
permissions:
  contents: read
  id-token: write
  attestations: write

steps:
  - uses: actions/checkout@v4
  # Build, test, stage, and write dist/SHA256SUMS here.

  - name: Attest release payloads
    uses: actions/attest@v4
    with:
      subject-checksums: dist/SHA256SUMS

  - name: Attest an SBOM with its payload
    uses: actions/attest@v4
    with:
      subject-path: dist/<portable-zip>
      sbom-path: dist/<portable-zip>.spdx.json
```

The exact workflow must use the current, reviewed major version of the official action and should pin third-party actions to reviewed commit SHAs in a production repository. Generate attestations only after the final artifact bytes and SBOM are present. A public repository’s visibility and GitHub plan can affect availability; check the current GitHub documentation before relying on the feature.

Users can verify the final artifact with GitHub CLI:

```sh
gh attestation verify <artifact> --repo <owner>/<repo>
gh attestation verify <artifact> --repo <owner>/<repo> \
  --predicate-type https://spdx.dev/Document/v2.3
```

The second command is for an SBOM attestation and uses the predicate type emitted by the chosen SBOM format. For offline or restricted environments, follow GitHub’s offline-verification procedure and retain the attestation bundle with the release evidence.

Artifact attestations are **not** Authenticode signatures, do not make a Windows publisher trusted, and do not suppress SmartScreen or Smart App Control. They answer “which workflow built these exact bytes?” rather than “which organization’s code-signing certificate signed this executable?” Publish both kinds of evidence when signing becomes available.

## 9. User verification guidance

The release page should provide a short, copyable verification procedure and enough context for a user to make an informed decision:

1. Download only from the canonical HTTPS GitHub Release or the reviewed project Scoop bucket. Confirm the version and source tag/commit.
2. Calculate SHA-256 locally and compare the full value with the published `SHA256SUMS`. Stop if the digest differs; do not “retry until it works.”
3. Verify the artifact attestation with `gh attestation verify`, and inspect the repository, commit, workflow, and subject digest. A missing or unverifiable attestation is a reason to pause, not a reason to bypass the warning.
4. For an optional installer, inspect its signature status before running it:

   ```powershell
   Get-AuthenticodeSignature -FilePath .\setup.exe |
     Format-List Status,SignerCertificate,TimeStamperCertificate
   ```

   An unsigned first release should be visibly documented as `NotSigned`/unsigned. A later release should be checked with `signtool verify /pa /v` and the expected publisher identity, not merely with a friendly filename.
5. Use Microsoft Defender or the organization’s approved scanner. Uploading a public artifact to a multi-engine service can disclose the file; do not upload confidential, pre-release, or user-specific builds.
6. Extract the portable ZIP into a user-writable directory and run the documented launcher with ordinary privileges. If Windows displays a security warning, verify the digest, attestation, source URL, and publisher story first. Use an OS-provided exception only as a deliberate, last-resort action for an artifact the user has independently verified; never disable protection globally.

The project should not provide a “bypass SmartScreen” button, script, registry change, Defender exclusion, or blanket PowerShell execution-policy instruction.

## 10. Later Windows signing path

Authenticode is the Windows signature format and `signtool.exe` is a signing/verification tool; Authenticode is not a certificate provider. It signs supported executable formats such as PE files and installers, not a ZIP archive as a publisher identity; use a detached signature or artifact attestation for the archive/checksum layer. Evaluate a legitimate identity only after the release process can protect it:

| Option | Appropriate use | Important limitation |
| --- | --- | --- |
| Authenticode with a public-CA code-signing certificate | A conventional direct-download release where identity and certificate lifecycle are available | A new publisher/file can still receive a SmartScreen warning while reputation develops |
| Azure Artifact Signing, formerly Azure Trusted Signing | Managed signing with Microsoft identity controls and CI federation | Eligibility, region, cost, and product naming change; it is not an instant SmartScreen bypass |
| SignPath | Policy-based signing through a trusted CI/build integration; evaluate the OSS program or a paid/self-hosted plan | Open-source eligibility and terms are not guaranteed; signing policies and approvals must be maintained |
| Self-signed certificate | Local development and isolated test environments only | Ordinary users do not trust it; never present it as public release signing |

When a real identity is available:

1. Choose one stable publisher identity and document its legal/organizational owner.
2. Protect the key in an HSM, hardware token, Azure managed signing service, SignPath service, or equivalent. Prefer short-lived OIDC/workload federation over long-lived cloud secrets.
3. Sign all relevant PE files and the final installer with Authenticode, using a reputable timestamp service. Sign nested payloads according to the packaging tool’s documented order; do not modify a file after signing.
4. Verify the signature chain, publisher, timestamp, and every embedded executable on a clean Windows machine.
5. Recompute SHA-256 for the exact signed bytes, generate/refresh the SBOM and GitHub attestation, and publish those values. Update the Scoop manifest only after the signed artifact has passed the same review.
6. Test SmartScreen and Smart App Control behavior honestly. Initial warnings remain possible even with a valid certificate; never promise a warning-free first release.

Until those controls exist, the portable ZIP plus Scoop path is the honest release strategy.

## 11. macOS: signing and notarization

An unsigned macOS build can be distributed with the same source link, checksum, SBOM, and artifact-attestation discipline, but Gatekeeper may warn users. Label the limitation rather than instructing users to disable Gatekeeper.

For a later macOS release:

1. Enroll in the Apple Developer Program and use a stable **Developer ID Application** identity (and **Developer ID Installer** where a signed `.pkg` requires it).
2. Enable hardened runtime, sign nested code from the inside out, and test both Apple Silicon and Intel artifacts or a correctly built universal binary.
3. Submit the exact distributable with `xcrun notarytool submit --wait`; inspect the notary log if it fails.
4. Staple the ticket with `xcrun stapler staple` and validate with `xcrun stapler validate`. Apple can notarize a ZIP, but a ticket cannot be stapled directly to a ZIP: staple the contained app/package where supported and recreate the ZIP only after stapling.
5. Verify the final artifact with `codesign --verify --deep --strict --verbose=2` and `spctl --assess --type execute --verbose=4`. Do not rebuild, re-zip, or otherwise modify the artifact after signing/notarization.
6. Store Apple API keys, issuer IDs, key IDs, app-specific passwords, and keychain profiles in protected CI secrets or an isolated runner. Delete temporary keychain material after the job. Never commit a `.p8`, certificate, or keychain file.

Notarization is not App Store review and does not guarantee that every user will see no warning. It is an important later trust layer, not a reason to weaken Gatekeeper.

## 12. Linux packages

Linux has no single “signed installer” format or reputation service equivalent to Windows SmartScreen. Publish the formats that match supported distributions and make the trust model explicit.

Recommended progression:

1. **Source archive first:** provide a tag-pinned source tarball, checksums, SBOM, and build instructions. This is the universal fallback.
2. **Portable AppImage (if the application supports it):** provide one artifact per supported architecture, include the required runtime, and publish SHA-256 (and an update/signature mechanism if the chosen AppImage tooling supports it). Test FUSE/runtime behavior on a clean distribution and state limitations.
3. **Debian/Ubuntu `.deb`:** build in a clean, pinned Debian or Ubuntu environment; declare dependencies, architectures, maintainer metadata, install/uninstall behavior, and file permissions accurately. Test installation, upgrade, removal, and a failed rollback. Do not bundle unvetted codecs, dictionaries, or other system libraries.
4. **Fedora/RHEL/openSUSE `.rpm`:** produce the appropriate package(s) with accurate dependencies and macros, and test on each supported distribution family. If an RPM repository is offered, protect its package metadata and signing key separately.
5. **Flatpak:** use a minimal sandbox permission set, bundle required runtime/dependencies, document host integration, and submit to Flathub only when the project is ready for its review and signing model. Flathub acceptance is not implied by publishing a tarball.
6. **AUR or other community repositories:** label them as community-maintained unless the project controls them. Do not call an AUR package an official binary without an explicit ownership and review process.

For an IME, document the required IBus/Fcitx/other desktop integration, data paths, permissions, and restart/log-out requirements. Avoid an installer that requests broad root access when a user-level package or portable build is sufficient. Debian repository signatures, RPM GPG signatures, Flatpak/OCI signatures, and artifact checksums solve different problems; document which one users should verify and how.

## 13. Release checklist

Before announcing a release, the release manager should be able to answer yes to each relevant question:

- [ ] Is the release built from a clean, protected tag and an exact source commit?
- [ ] Are all submodules and third-party components pinned and license-reviewed?
- [ ] Are the canonical product name, repository, version, and artifact names consistent?
- [ ] Are lockfiles and toolchain versions recorded, and was the unsigned payload built twice for comparison?
- [ ] Do tests and clean-machine smoke tests pass for every supported architecture?
- [ ] Is the portable ZIP the documented primary Windows path?
- [ ] Does the Scoop manifest use the exact ZIP URL, version, extraction path, launcher, and SHA-256?
- [ ] Is an optional Inno Setup/NSIS installer clearly marked unsigned and built from the same payload?
- [ ] Are `SHA256SUMS`, the SBOM, build manifest, and artifact attestation attached to the release?
- [ ] Does the release page explain SmartScreen/Smart App Control warnings and provide verification steps?
- [ ] Are no secrets, user data, local dictionaries, or unreviewed generated files included?
- [ ] Are macOS artifacts signed/notarized/stapled when that channel is enabled?
- [ ] Are Linux package dependencies, permissions, install/uninstall paths, and repository-signing status documented?
- [ ] Are release assets immutable, and is there a plan for a security revocation or yank?

## References

- [Microsoft: SmartScreen reputation for Windows app developers](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation)
- [Microsoft: Windows code-signing options](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options)
- [GitHub: Use artifact attestations to establish build provenance](https://docs.github.com/actions/secure-your-work/use-artifact-attestations/use-artifact-attestations)
- [Scoop documentation](https://docs.scoop.sh/)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [SPDX](https://spdx.dev/) and [CycloneDX](https://cyclonedx.org/)
- [SignPath documentation](https://docs.signpath.io/)
