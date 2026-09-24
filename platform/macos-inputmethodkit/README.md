# macOS InputMethodKit adapter

Target: an InputMethodKit application with one `IMKInputController` per client session and a thin Objective-C++ bridge to the KanaAI Rust helper.

The shell owns only lifecycle, key translation, candidate presentation, selection ranges, accessibility, and secure-input behavior. Conversion, personalization, local model orchestration, persistence, and privacy policy remain in Rust/Mozc.

A future release must be Developer ID signed, hardened, notarized, and stapled; the current source repository is not a signed macOS distribution.
