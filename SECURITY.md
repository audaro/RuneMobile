# Security Policy

This is a single-maintainer, best-effort project. Only the latest published
release is supported.

## Reporting a vulnerability

Please report privately — **do not** open a public issue for a security problem.

- Preferred: open a private [GitHub Security Advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  on this repository.
- Or email the maintainer: `sayhijordy@gmail.com`.

Expect a best-effort response. Please give enough detail to reproduce.

## In scope

- The native mobile shell (Kotlin/Compose, Objective-C/UIKit) and the C++ native layer.
- On-device login and token handling (Jagex OAuth and the optional RuneLite-account sync).
- The embedded-JVM / plugin trust boundary.

## Out of scope (accepted risks, not vulnerabilities)

- **Account ban risk.** This client is not on Jagex's approved-client list. Using
  it can get an account banned. This is irreducible — use a throwaway account.
- **In-process hub plugins.** Plugins run inside the embedded JVM with full JVM
  privileges, by design (this is how RuneLite works). Auditing third-party hub
  plugins is the user's responsibility.
- **Tokens at rest.** OAuth tokens are kept in app-private storage; no live
  `tokens.json` is shipped in any build.
- **Android login transits the system clipboard.** The Jagex sign-in returns its
  `id_token` by having you copy the `http://localhost/#…` redirect link; anything
  on the clipboard is briefly visible to whatever else can read it (keyboards,
  clipboard managers, pre-Android-10 background apps). Mitigations in place: the
  return leg is bound to the app's own OAuth `state` + `nonce` (a planted foreign
  link is rejected), and the clipboard is cleared the moment the token is
  captured. The residual exposure window — between your copy and the app's read —
  is inherent to the flow and accepted.

## Build & supply chain

The build pins or sources its heaviest inputs deliberately:

- **Embedded JDK / AWT runtime** (OpenJDK 21 + Caciocavallo) — fetched at build time from a pinned
  upstream and verified by **SHA-256** before use (`tools/stage-android-jre.sh`); a mismatch aborts the
  build. These runtimes are not committed to the repo.
- **Native libraries** (`librunemobile`, `librlawt`) — built from **tracked C++ source** by Gradle/CMake,
  not downloaded as binaries.
- **Gradle dependencies** — resolved from declared repositories (Maven Central, Google, the Gradle Plugin
  Portal, and RuneLite's Maven repo) at pinned versions over HTTPS. Per-artifact checksum verification
  (Gradle `verification-metadata.xml`) is **not** enabled, so the integrity of these JARs rests on the
  repositories and transport at fetch time, **not** on committed checksums — that is the residual
  supply-chain exposure here. This is a deliberate trade-off: on a fork that tracks upstream RuneLite
  closely, full verification breaks every build on each dependency bump, and the highest-risk inputs (the
  JDK runtime and the native layer) are already pinned by SHA / built from source. If you require
  byte-level guarantees, generate and build from a local manifest:
  `./gradlew --write-verification-metadata sha256`.
- **No build-time telemetry**, and R8/minification is intentionally off, so the shipped bytecode
  corresponds directly to the tracked source (the third-party dependency JARs excepted, per the note
  above).

## Handling credentials in reports

Never paste a real `session_id`, `id_token`, access/refresh token, or password
into an issue, PR, or log attachment. Redact account display names. Treat any
logcat/console capture as potentially containing identifiers.
