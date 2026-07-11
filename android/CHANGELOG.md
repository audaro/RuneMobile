# Changelog

All notable changes to the Android app are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The `versionName` in
`app/build.gradle.kts` is the semver below; `versionCode` is derived from it
(`major*10000 + minor*100 + patch`) and is strictly increasing so Android
accepts update-in-place.

## [Unreleased]

## [0.1.0]
Initial pre-release of the native Android client: real RuneLite headless on an
embedded arm64 OpenJDK 21, CPU/base-GPU/117HD renderers (caps-probed), Jagex
OAuth + RuneLite-account sync, native HUD/chat/tab-grid veneers, plugin panel.

### Notes
- Unofficial, sideload-only — not affiliated with or endorsed by Jagex/RuneLite;
  use at your own risk including account ban. See README.
- Release signing: a dedicated key via `keystore.properties` when present, else
  the debug key (see `keystore.properties.example`).

[Unreleased]: https://github.com/audaro/runemobile/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/audaro/runemobile/releases/tag/v0.1.0
