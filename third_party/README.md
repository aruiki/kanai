# Third-party boundary

`mozc/` is a pinned git submodule and is not part of KanaAI-authored Rust code.

KanaAI keeps a small patch file under `patches/` for the local bridge needed by the lab and future native adapters. The patch is applied by `scripts/build-mozc-bridge.sh`; the submodule pointer remains traceable to an upstream commit.

The Mozc code and dictionary/data terms are not replaced by KanaAI's project license. Release tooling must carry the upstream license, dictionary notices, and a generated third-party notice manifest.
