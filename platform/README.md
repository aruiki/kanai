# Native adapter boundary

The native packages are intentionally thin. They translate OS input events to the versioned KanaAI shell contract and render KanaAI state. They must not contain a second Japanese conversion engine, a second learning store, or an implicit network client.

| Platform | Framework | First target |
|---|---|---|
| Linux | Fcitx5 | yes |
| Windows | TSF TIP | planned |
| macOS | InputMethodKit | planned |

The Rust core is the source of truth for session generation, mode policy, candidate ordering, local model decisions, and privacy. See [`PLATFORM_ROADMAP.md`](../docs/PLATFORM_ROADMAP.md) for release gates.
