# Mozc bridge patch

This directory contains the reviewed patch applied to the pinned Mozc submodule. It is intentionally kept as a patch rather than silently modifying a floating upstream checkout.

The bridge exposes a small, line-oriented process protocol to the Rust `kanai-mozc` adapter. It does not change Mozc's dictionary, language model, candidate ordering, or license boundary.
