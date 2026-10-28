# 来源与依赖 / Provenance and dependencies

本副本整理自 KARI-DF26-WEB 项目中的 iOS 实现，保留原始眼睛动画和机器人动作代码。没有复制原仓库 Git 历史或赋予原有代码新的许可条款。

This extraction comes from the iOS implementation in KARI-DF26-WEB and retains its original eye animation and robot motion code. Original Git history is not included. No new license grant is asserted for the extracted code.

- Source: maintainer’s pre-migration iOS development snapshot, retained in the private historical archive. New repository history starts with this KARI distribution.
- GoogleSignIn-iOS (runtime dependency): https://github.com/google/GoogleSignIn-iOS — Apache-2.0; transitive dependencies retain their own licenses.
- esbuild (optional resource build tool): https://github.com/evanw/esbuild — MIT.
- Playwright (optional UI checks): https://github.com/microsoft/playwright — Apache-2.0.

Dependency source and license notices are supplied by Swift Package Manager / npm when resolving dependencies. This repository does not vendor their source trees.

## Local vision model and runtime (1.2.0)

EfficientDet-Lite0 int8 model: unmodified Google model, Apache-2.0. SHA-256 and source: `docs/model-manifest.json`. MediaPipe Tasks Vision is pinned to revision `e9794ef55e2509c09aa8b6ba1764b797db8eb200`; dependency licenses remain applicable. License texts for MediaPipe, TensorFlow Lite and bundled native components are retained in `licenses/`.

The fixed burger test fixture comes from Google's MediaPipe sample assets: https://storage.googleapis.com/mediapipe-assets/burger.jpg . It is used only for detector regression tests.

## KARI 图标 / KARI icon

`App/AppIcon.icon`、`icon.png` 及 README 图标采用维护者于 2026-10-28 确认的原创 KARI 字形和对齐格纹，替代此前占位图标。图形与商标权利保留。

`App/AppIcon.icon`, `icon.png`, and the README icon use the original KARI letterform and aligned grid approved by the maintainer on 2026-10-28, replacing the former placeholder. Artwork and trademark rights are reserved.
