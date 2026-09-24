# Fcitx5 adapter

Target: a small Fcitx5 input-method addon that forwards normalized key/edit events to the KanaAI Rust service and renders preedit/candidate events through Fcitx APIs.

This directory is the integration seam, not a second implementation. The addon must:

- keep one session per Fcitx input context;
- destroy stale preedit/candidate state on focus loss;
- use the Rust shell protocol version;
- respect password/no-learning capabilities;
- avoid synchronous dictionary, model, disk, or network work;
- pass keyboard accessibility and DPI tests.

The current repository does not yet claim a production Fcitx5 binary. The core and Mozc bridge are built first so the native ABI can be conformance-tested.
