# Pull request

<!-- markdownlint-disable MD013 -->

## Summary

<!-- Explain the user or maintainer problem and the chosen solution. -->

## Related issue or design

<!-- Link an issue or document the relevant architecture/privacy decision. Use "None". -->

## Type of change

- [ ] Rust core, Mozc adapter, CLI, or API
- [ ] TypeScript development workbench
- [ ] Native Linux, Windows, or macOS shell
- [ ] Dependency, CI, packaging, Scoop, or release tooling
- [ ] Documentation, security, privacy, licensing, or data
- [ ] Other:

## Validation

<!-- List exact commands and platforms. Do not claim an unrun check. -->

- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --locked --workspace --all-targets -- -D warnings`
- [ ] `cargo test --locked --workspace --all-targets`
- [ ] `npm test`
- [ ] `npm run build`
- [ ] Relevant Mozc/native/manual checks, described below

## Safety checklist

- [ ] No API key, signing material, private profile, model weight, user text, real dictionary, or production log is included.
- [ ] New dependencies, submodules, code, data, models, and notices were reviewed and recorded.
- [ ] Networking, context capture, learning, persistence, deletion, and secure-input behavior are documented and tested where relevant.
- [ ] The change fails safely on timeout, provider failure, malformed input, missing key storage, and process restart where applicable.
- [ ] User-facing copy does not claim a shipped native IME, bundled model, stable release, signing, or benchmark result that does not exist.
- [ ] UI changes include desktop and mobile visual checks at approximately 1440 px and 390 px when UI is in scope.
- [ ] Documentation and tests use synthetic or license-clean material.

## Screenshots or recordings

<!-- Required for visual changes. Describe desktop and mobile states; do not include private content. -->

## Compatibility and rollout

<!-- Describe migration, architecture, data schema, native ABI, protocol, or packaging impact. -->

## DCO

- [ ] Every commit includes a `Signed-off-by:` trailer.
