# Security Policy

## Project status

KanaAI is an engineering project. The retired Workbench/CLI path is not a
Windows beta or IME, and no native TSF installer, supported release channel, or
public signing identity exists today. Security fixes are handled on a
best-effort basis for the current development line until a supported release
policy is established.

Do not assume that source availability, a checksum, a Scoop manifest, or a
GitHub artifact attestation proves that a binary is vulnerability-free. See the
[distribution plan](docs/DISTRIBUTION.md) for what each trust signal does and
does not establish.

## Reporting a vulnerability

**Do not open a public issue, discussion, or pull request for an unreported
vulnerability.**

Use GitHub's private vulnerability reporting form:

<https://github.com/aruiki/kanai/security/advisories/new>

If private reporting is not yet enabled on the repository, contact the
repository owner through a private channel available at
<https://github.com/aruiki> and ask them to enable private vulnerability
reporting. Do not include exploit details in a public request for help.

Please include, where safe:

- affected component and commit or source version;
- operating system, architecture, Rust/Node/Bazel/Mozc versions when relevant;
- prerequisites and exact reproduction steps;
- expected and observed behavior;
- impact and required attacker position;
- a minimal synthetic proof of concept; and
- redacted logs or crash output.

**Never attach API keys, signing material, real model files, personal
dictionaries, typed user text, production traffic, or an unredacted profile.**
Use synthetic content and a canary string. If a secret may have been exposed,
rotate or revoke it before contacting maintainers.

There is no guaranteed response-time SLA. Maintainers aim to acknowledge a
complete report promptly, assess impact, coordinate a fix, and coordinate
disclosure. The reporter will normally be credited if desired and disclosure
does not create a security risk.

### Supported versions

| Version/source | Security support |
| --- | --- |
| `0.1.0` development source | Best effort; this is not a published release |
| Current `main` | Reviewed as development code; no compatibility guarantee |
| Older source | Unsupported; only reproducible KanaAI defects are in scope |

When a public release is created, this table must name supported release lines,
an end-of-life policy, and the expected patch channel.

## Security boundaries to test

Particular attention should be paid to:

- native Fcitx, TSF, and InputMethodKit ABI, focus, preedit, and candidate
  handling when those shells exist;
- key, commit, cancellation, and stale-generation handling;
- Mozc bridge framing, UTF-8 boundaries, process death, and endpoint/peer
  isolation;
- password, protected, direct-input, and Protect Mode behavior;
- local IPC authentication, file permissions, and profile deletion;
- learning from displayed versus confirmed candidates;
- API authentication, binding, request limits, and cross-origin exposure;
- API-key handling, remote-provider gating, redirects, and response parsing;
- serialized learning-state, import, migration, and rollback handling;
- prompt/output/log redaction and denial-of-service limits for model paths;
- dependency, CI, release, Scoop, update, and artifact provenance behavior; and
- third-party or model data entering a release without required review.

The current developer API is unauthenticated and loopback-bound. Do not expose
it to an untrusted network or treat loopback binding as authentication. A
future Windows TSF package must be treated as unsigned until a trusted publisher
signature exists; verify its digest and source before running it. These are
known development limitations, not evidence that the service is safe for
production deployment.

## Out of scope

The following are not vulnerabilities by themselves:

- incorrect Japanese conversion, candidate order, or model output;
- undesirable personalization that does not violate a documented privacy
  boundary;
- reports against Google's Mozc project without a KanaAI-specific integration
  risk;
- missing native functionality already listed as a roadmap item;
- unsigned status alone; or
- theoretical model output quality without a reproducible security impact.

A report may still be valuable even when outside these categories. Use a
public issue only after confirming that it contains no sensitive information or
undisclosed security impact.

## Safe research

Good-faith research is welcome when it:

- uses accounts, profiles, and test data you own;
- avoids service degradation, privacy violations, persistence, and social
  engineering;
- does not obtain or access another user's data;
- gives maintainers a reasonable opportunity to address a critical issue before
  disclosure; and
- follows applicable law and GitHub's acceptable-use rules.

Do not weaken Defender, Smart App Control, Gatekeeper, SmartScreen, antivirus,
or enterprise policy to test KanaAI. If a separately published unsigned beta is
available, download it only from the canonical release, verify its external
SHA-256 and provenance, and stop if they do not match. Build from reviewed
source when no trusted artifact is available.

## Disclosure and release handling

For a confirmed issue, maintainers will:

1. contain or mitigate active risk where possible;
2. prepare and review a regression test without publishing sensitive data;
3. document affected versions and safe workarounds;
4. coordinate a fixed release and final artifact hashes/SBOM/provenance; and
5. publish an advisory when users need awareness or action.

Do not disclose a suspected exploit publicly merely to pressure maintainers.
Open development discussion should use a safe, synthetic description until a
fix and coordinated disclosure are ready.

## Security-sensitive contributions

See [CONTRIBUTING.md](CONTRIBUTING.md). Never put credentials in a fork job,
workflow, log, or release asset. Changes to workflows, networking, subprocesses,
native loading, serialization, update logic, packaging, or signing policy need
extra review.
