# Open-source and release guidelines

**Status:** project-wide baseline for contributions, maintenance, and public releases.

These guidelines describe the minimum behavior expected of contributors and maintainers. They are not a substitute for the project license, a security advisory, or legal advice. The concrete artifact and platform procedures are in [`DISTRIBUTION.md`](./DISTRIBUTION.md).

## 1. Project commitments

The project should remain:

- **Open:** source, build instructions, tests, and relevant design documentation are published under a clear license; users can inspect and rebuild the software.
- **Reproducible:** a release records exact source, dependency, toolchain, and packaging inputs, and uses checksums and provenance so another person can verify what was built.
- **Privacy-respecting:** local-first behavior is the default; data collection, network calls, API use, and user-data storage are disclosed and opt-in where appropriate.
- **Secure by default:** maintainers do not ask users to disable operating-system security controls, conceal an unsigned artifact, or trust an unverified download.
- **Accessible and maintainable:** user-facing changes include appropriate documentation, tests, localization considerations, and an explanation of compatibility impact.
- **Factually precise:** release notes distinguish source availability, unsigned status, package-manager integrity, provenance attestation, and operating-system code signing.

Open source does not mean that every binary is safe to run. It means that the source and its constraints are public and that the project provides enough evidence for users to make an informed trust decision.

## 2. Roles, review, and decision-making

The project should identify maintainers and, at minimum, designate these responsibilities:

| Responsibility | Minimum expectation |
| --- | --- |
| Maintainer/reviewer | Reviews changes, protects the default branch, and follows the contribution process |
| Release manager | Builds from an approved tag, verifies artifacts, and publishes release metadata |
| Security contact | Receives private reports and coordinates disclosure and fixes |
| Dependency/licensing reviewer | Reviews new dependencies, submodules, data/model files, and notices |

No single person should be the sole approver for source changes and a public release. Require a second maintainer for release approval, signing requests, security-sensitive changes, and changes to packaging or release workflows. Protect the default branch, require review for workflow and dependency changes, and use `CODEOWNERS` or an equivalent review requirement for packaging, CI, and signing-policy files.

Record material decisions in a public issue, pull request, release note, or accepted governance document. Do not make a licensing, telemetry, signing, or security-policy change silently. Maintainers may amend these guidelines through the same review process used for other project policies.

Choose a contribution agreement deliberately:

- If using a Developer Certificate of Origin, document it and provide the required sign-off mechanism.
- If using a Contributor License Agreement, explain why it was chosen and do not require one retroactively without a maintainer decision.
- Do not present an unreviewed legal agreement as a mandatory contribution rule.

A code of conduct, security policy, and issue templates should be easy to find. They must be enforced consistently and should not be used to hide technical decisions or reject a contribution for an unrelated reason.

## 3. Contribution requirements

A useful pull request:

1. Explains the user or maintainer problem, not only the code change.
2. Keeps the change scoped enough for a meaningful review.
3. Adds or updates tests, fixtures, documentation, and compatibility notes as appropriate.
4. Uses committed lockfiles and does not silently upgrade unrelated dependencies.
5. Does not add generated binaries, local logs, user dictionaries, API keys, `.env` files with values, or machine-specific build output to the repository.
6. Discloses new third-party code, data, models, fonts, icons, or dictionaries and includes the required license or source information.
7. Explains any material AI-generated contribution, especially when correctness, licensing, privacy, or provenance cannot be independently checked.
8. Passes formatting, type checking, unit/integration tests, and the relevant security/license checks before merge.

A contributor must not include credentials, signing material, private user data, or captured production traffic in a pull request. A pull request from a fork must never receive release or signing secrets merely because it is open.

## 4. Licensing and third-party provenance

### License consistency is a release requirement

The KanaAI-authored source is currently declared `MIT OR Apache-2.0` in the
workspace/package metadata, with both complete texts and a root license
pointer. Before the first public binary, re-check that every package metadata
field, notice, and generated artifact uses the same expression. Do not apply
the KanaAI project license to Mozc, dictionaries, models, or other third-party
components; ship their applicable terms separately.

The source archive and every binary package must include:

- the project license and copyright notice;
- third-party license and attribution notices;
- a list of bundled components and their source locations;
- any required source-offer, attribution, or redistribution information; and
- a clear statement of which components are optional or user-supplied.

A dependency’s package metadata is a starting point, not proof that its license or data rights are compatible. A code license does not automatically grant rights to a dictionary, model, vocabulary, font, or other data file.

### Submodules and bundled data

`third_party/mozc` is a pinned third-party source dependency and has its own licensing and vocabulary policy. Before redistribution:

- record the exact submodule commit and include its required notices;
- review the upstream license and build requirements;
- read and comply with `third_party/mozc/VOCABULARY_POLICY.md` for any dictionary or generated data;
- verify that every bundled binary, dictionary, and generated file is permitted for the intended distribution; and
- do not imply that this project is an official Google/Mozc release or that upstream branding applies to this project.

Apply the same review to AI models, prompts, training data, API clients, and model output. An API key or a model name is not a redistribution license. If an external service is required, document the terms, data sent, retention behavior, and an offline fallback where feasible.

### Dependency and update policy

Use a written policy for adding dependencies. Prefer maintained, auditable libraries with clear licenses and reproducible package metadata. For every new dependency, record:

- why it is needed and the alternative considered;
- its pinned version, source, and integrity mechanism;
- its license and transitive dependency implications;
- whether it is shipped in the artifact or only used to build/test; and
- the SBOM and vulnerability-monitoring treatment.

Lockfiles, container digests, and submodule gitlinks are part of release provenance. Do not use a floating URL, an unpinned installer downloaded during a release, or an unreviewed latest-version tool to assemble a public binary.

## 5. Reproducibility and build hygiene

A contributor should be able to build the source using documented prerequisites. A release manager should additionally be able to explain exactly which bytes were produced.

Required practice:

- build from a clean, protected tag or exact commit;
- initialize and pin all submodules recursively;
- use `npm ci` and other lockfile-aware installs, with Rust `--locked` where applicable;
- pin Node, Rust, compilers, linkers, archive tools, and packaging tools to exact versions;
- use a clean, declared build environment and a fixed locale/time zone;
- set `SOURCE_DATE_EPOCH` from the commit timestamp and normalize archive metadata;
- keep secrets and machine-specific paths out of the build;
- generate an SBOM and a build/provenance manifest;
- build the unsigned payload twice where practical and compare SHA-256 values; and
- document unavoidable non-determinism instead of making an unsupported reproducibility claim.

Do not commit a locally built ZIP, `setup.exe`, `.dmg`, `.pkg`, `.deb`, `.rpm`, AppImage, or Flatpak. A release asset is a CI output whose source, hash, and build environment must be auditable. If an installer tool embeds a timestamp, random value, or build path, test and document that limitation before signing; do not “fix” it by editing a signed binary.

## 6. Security and privacy

### Reporting and disclosure

Provide a monitored private security-reporting channel. A reporter should be able to provide a reproduction, affected version, impact, and logs without posting exploit details publicly. Maintainers should acknowledge reports, assess impact, coordinate a fix and disclosure timeline, and publish a security advisory when users need mitigating action. Never suppress a vulnerability merely because a binary is unsigned or because fixing it is inconvenient.

Maintain a supported-version policy. Critical issues should have a documented patch path, and release notes should distinguish security fixes from ordinary features. Preserve enough evidence to investigate a compromised release, including workflow run IDs, source SHAs, artifact digests, SBOMs, and signing/attestation records.

### Local-first data and credentials

The project’s local-first promise is a security boundary:

- document every file, dictionary, history entry, log, and network request the application creates;
- keep user data out of source, SBOMs, logs, test fixtures, and release artifacts;
- make deletion/export behavior clear;
- do not add telemetry or analytics without an explicit product decision and disclosure;
- obtain consent before sending text or user data to a configured external API; and
- treat API keys as server-side secrets, never as values embedded in a browser bundle or portable ZIP.

The current environment variable example is a reminder, not a distribution mechanism. A release build must fail closed if an optional API key is missing, must not print it, and must not ship a developer `.env` file. Test the packaged application with a clean user profile and with no secret present.

### Security checks for changes

Use automated dependency and secret scanning where available. Review changes to install scripts, CI workflows, update logic, subprocess invocation, file permissions, network endpoints, and serialization. Do not add broad Windows Defender exclusions, PowerShell execution-policy bypasses, macOS Gatekeeper bypasses, or Linux `sudo` scripts as a convenience feature.

A checksum is not a substitute for authentication, and a GitHub artifact attestation is not a malware guarantee. Release guidance must describe the exact evidence being provided and its limitations.

## 7. Release governance

A release is a reviewed operation, not an informal upload from a maintainer’s workstation.

1. Choose a SemVer version and create a protected `vX.Y.Z` tag. Use an annotated or signed Git tag where feasible; Git-tag signing and binary signing are separate controls.
2. Generate a changelog and release notes with the source SHA, supported platforms/architectures, prerequisites, migration notes, known limitations, and security warnings.
3. Build and test from the tag in a clean environment, including the reproducibility comparison described in `DISTRIBUTION.md`.
4. Generate checksums, the SBOM, the build manifest, and GitHub artifact attestations. If signing is enabled, sign the final bytes and then calculate the final checksum and attestation.
5. Obtain the required second-maintainer approval, upload assets once, and record the workflow/release URLs.
6. Verify the public download and the verification commands on a clean machine. Do not overwrite an asset with a different build; issue a new version or a documented security revision instead.

Release assets should be immutable from the user’s perspective. If an artifact is compromised, preserve evidence, stop publishing, notify users through the security channel, and mark the release withdrawn according to the hosting platform’s capabilities. A tag, checksum, and attestation without a trustworthy release account are not enough to make a compromised build safe.

## 8. What release evidence proves

Maintainers and users should not conflate these controls:

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| SHA-256 checksum | The downloaded bytes match the recorded digest | Who built the bytes, unless the checksum itself is independently authenticated |
| GitHub artifact attestation | The artifact digest was produced by an identified GitHub workflow/source context | Windows publisher trust, absence of vulnerabilities, or a malware-free result |
| Scoop manifest hash | Scoop’s downloaded input matches the reviewed manifest | A code signature, publisher identity, or SmartScreen exemption |
| Authenticode signature | Windows can validate the signer certificate and signed file content | A guarantee of safe behavior, bug-free software, or zero first-download warnings |
| Apple notarization ticket | Apple’s notary service processed the signed macOS distributable | App Store review, absence of every vulnerability, or a promise of no Gatekeeper warning |
| Debian/RPM/Flatpak/OCI signature | The package or repository artifact matches its signing key/trust policy | General trust in every upstream dependency or source commit |

Release notes should label an unsigned artifact plainly. A future signed artifact should retain the same checksum, SBOM, provenance, and reproducibility evidence rather than replacing trust signals with a single certificate.

## 9. Signing and signing-secrets policy

### Current state

The project currently has no authorized public release-signing identity. Until a maintainer deliberately adopts one:

- do not commit a certificate, private key, self-signed public certificate, Apple key, GPG key, or signing-service token;
- do not use a developer laptop as a release-signing authority;
- do not sign a test certificate and describe it as a public trust signal;
- do not put signing credentials in a fork, issue, pull request, workflow log, release asset, or build cache; and
- publish the portable ZIP and optional unsigned installer with the verification and warning guidance in `DISTRIBUTION.md`.

The absence of a certificate is a distribution limitation, not permission to weaken a user’s security controls. `setup.exe` naming does not bypass SmartScreen, and neither does an archive or a package manager.

### Prohibited secret locations

The following must never be committed or exposed to an untrusted build:

- `*.pfx`, `*.p12`, `*.pem`, `*.key`, `*.jks`, `*.keystore`, Apple `*.p8`, or exported private-key files;
- Azure client secrets, access tokens, or signing credentials not protected by workload identity;
- SignPath API tokens or administrative credentials;
- Apple App Store Connect API keys, issuer secrets, app-specific passwords, or keychain exports;
- Debian/RPM/Flatpak signing private keys and passphrases;
- npm, package-registry, cloud, CI, or release tokens; and
- `.env` files containing values, even when `.env.example` is committed.

Public certificates, public keys, certificate fingerprints, and non-secret signing-policy configuration may be published when they are useful for verification. Rotate or revoke any secret that may have been exposed, preserve the incident record, and do not continue a release merely to avoid delaying users.

### Preferred secret handling

| Secret or authority | Preferred handling | Access and review |
| --- | --- | --- |
| Windows Authenticode private key | HSM, hardware token, or managed signing service; sign in a protected release environment | Named release role, MFA, least privilege, two-person approval |
| Azure Artifact Signing/Trusted Signing | OIDC/workload identity federation to the managed service where supported; no exported private key | Restrict subject/repository/environment claims; separate signing job |
| SignPath | Scoped submitter token plus a protected signing policy and trusted-build/origin verification | Token available only to the release job; policy changes reviewed |
| GitHub artifact attestations | GitHub Actions OIDC and the `actions/attest` workflow; no long-lived signing key | Grant `id-token: write` and `attestations: write` only to the attesting job |
| Apple notarization | App Store Connect API key or app-specific password stored in the CI secret store, injected into a temporary keychain | macOS release runner only; delete keychain/profile after use |
| Linux repository/package signing | Offline or HSM-backed GPG/repository key with a documented rotation/revocation process | Separate from build credentials; sign only approved package metadata |

Use short-lived, narrowly scoped credentials wherever possible. Store secrets in the CI provider’s protected secret store or an external vault, not in repository variables that ordinary jobs can read. Use environment protection, required reviewers, branch/tag rules, and explicit workflow permissions. Restrict `id-token: write`, `attestations: write`, package-publish permissions, and release tokens to the individual job that needs them.

### CI and workflow requirements for signing

A future signing workflow must, at minimum:

1. Run only from a protected, reviewed release tag or an equivalently controlled release event.
2. Check out the exact source SHA and verify submodules, lockfiles, and the unsigned artifact digest.
3. Build in an isolated runner and pass only the tested artifact to the signing service; do not let a user-provided URL or arbitrary uploaded file reach the signer.
4. Separate build/test permissions from signing/publish permissions. Prefer a protected environment and a two-person approval for the signing request.
5. Pin third-party actions and tools to reviewed versions or commit SHAs. Do not run unreviewed code from a pull request with access to signing credentials.
6. Avoid `pull_request_target` or similar patterns that expose secrets to forked/untrusted code. Never print secrets, disable command logging around a secret, or upload runner logs containing them.
7. Use a stable publisher identity, timestamp the signature, verify the final signature and embedded files, and stop publication on any mismatch.
8. Recompute checksums and attestations after signing, and retain the unsigned build record for comparison.
9. Maintain a revocation/rotation plan and an incident response for a compromised workflow, runner, account, or signing service.

SignPath’s open-source offering, if pursued, has eligibility and policy requirements; review the current terms rather than assuming sponsorship. Publish a clearly labeled **Code signing policy** on the project’s release/documentation pages, identify the signing team, and link it from every download page. Azure Artifact Signing (formerly Azure Trusted Signing) changes branding, regions, and eligibility over time; verify the current Microsoft documentation before implementation. Authenticode requires a legitimate certificate or managed authority; a self-signed certificate is for test environments only.

### Signing verification before publication

For a future Windows release, verify at least:

```text
Get-AuthenticodeSignature <setup.exe>
signtool verify /pa /v <setup.exe>
```

Also verify every shipped executable/driver/component covered by the chosen signing policy, the expected signer subject/thumbprint, the timestamp, and the certificate chain on a clean supported Windows image. A valid signature on an outer installer does not automatically mean every embedded binary is signed. Record the verification output in the release evidence without recording private key material.

## 10. Platform expectations

### Windows

The first release is expected to be unsigned. The portable ZIP and reviewed Scoop manifest are primary; Inno Setup/NSIS `setup.exe` is optional. The current Windows beta is a portable Workbench/CLI package, not a completed TSF keyboard. Communicate SmartScreen and Smart App Control behavior accurately. Later, use Authenticode with a trusted identity, Azure Artifact Signing/Trusted Signing, or SignPath under this policy.

### macOS

Until a Developer ID identity is available, label Gatekeeper warnings and provide source, checksums, SBOM, and attestation. Later, use Developer ID signing, hardened runtime, `notarytool`, stapling, and final-artifact validation. Keep Apple credentials out of the repository and remove temporary keychain material.

### Linux

Publish source and checksums first, then add only the package formats the project can test and maintain: AppImage, `.deb`, `.rpm`, Flatpak, or another explicitly supported format. Declare dependencies, permissions, IBus/Fcitx integration, and install/uninstall behavior. Repository/package signatures and checksums are separate controls, and community repositories such as the AUR must be labeled as such.

## 11. Review checklists

### Before merging a change

- [ ] The change is scoped, reviewed, tested, and documented.
- [ ] No credentials, user data, local state, or unreviewed generated binaries were added.
- [ ] New dependencies, submodules, data, and licenses were reviewed and recorded.
- [ ] Lockfiles, source maps, build paths, and network behavior were checked for supply-chain or privacy impact.
- [ ] CI/workflow permissions and action references are safe and pinned.

### Before publishing a release

- [ ] The canonical name, version, repository, and license are consistent.
- [ ] A clean tagged build and a second reproducibility comparison are recorded.
- [ ] Tests and clean-machine smoke tests pass for every advertised target.
- [ ] SHA-256 checksums, SBOM, build manifest, and GitHub artifact attestation are attached.
- [ ] The Windows ZIP is primary, the Scoop manifest hash/path is tested, and any optional installer is clearly unsigned.
- [ ] macOS signing/notarization/stapling or Linux package-signing status is accurately stated.
- [ ] Release notes explain expected security warnings and user verification steps.
- [ ] A second maintainer approved the release and no secrets entered the artifact or logs.

## 12. Maintaining these guidelines

Review this document and [`DISTRIBUTION.md`](./DISTRIBUTION.md) whenever the toolchain, supported operating systems, dependency policy, release hosting, signing provider, or legal/licensing status changes. Record the reason for each change, update user-facing verification instructions at the same time, and test the documented commands from a clean environment. A guideline that cannot be followed safely should be corrected before the next release rather than left as aspirational text.
