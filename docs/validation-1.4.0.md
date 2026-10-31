# Public iOS 1.4.0 validation

Date: 2026-10-31 (Asia/Shanghai). Migrated from the local 1.4.0 build 16 canonical sources. Personal signing, OAuth settings, device identifiers, document data and embedding weights are excluded.

## Executed on the public project

- Localization: 646 keys, two languages and five permission descriptions per language passed.
- Desktop native checks: 95 protocol/configuration checks, 28 remote-control checks, 49 feature checks, device-session checks and actual URLSession transfer tests passed.
- Memory harness: atomic persistence/rollback, checkpoints, ranking, endpoint/credential isolation, provider requests and malformed response handling passed. Uses the pinned locally rebuilt llama runtime; no cloud API calls.
- Unsigned generic iOS Debug build and device test-target compilation passed, including MemoryRegressionTests.
- Chrome face/animation bridge tests: 2 passed.

## Pending physical verification

The paired iPhone was unavailable during this run. Memory extraction/OCR and five local models have historical personal-project results, but those do not count as a fresh public-project device pass. The migrated app still needs physical installation and runtime checks, including Live document questions, model download recovery and iOS 15 hardware. No speaker, microphone, camera or robot acceptance is inferred from compilation.

## Reproducible runtime

Run `npm run build:embedding` before opening a fresh clone in Xcode. It builds llama.cpp revision `78feec062d50ec9e8940244cac918ac4480b60cb` for iOS 15 (device and simulator) and macOS. Generated frameworks are ignored by Git; `licenses/LLAMA-LICENSE` is included. This run reused that pinned runtime from the local personal build.
