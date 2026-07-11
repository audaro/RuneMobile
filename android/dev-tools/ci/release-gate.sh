#!/usr/bin/env bash
# Android release gate — the single, runnable "a real gate exists and passes" check (GATE.md row 6).
#
# This script IS the gate. CI (.github/workflows/android-release-gate.yml) is a thin wrapper that calls it,
# but the gate is fully reproducible on a developer machine — so it has real, observable evidence even while
# GitHub Actions are disabled at the repo level (this fork ships an unapproved live-OSRS client and is never
# published to a marketplace, so CI is dormant-but-ready, not the source of truth). Findings covered:
#   PROD-QA-01          — build a signed :app:assembleRelease, lint it, run the shared-contract check (+ a
#                         device-smoke stage that is opt-in: it needs a real device / Firebase Test Lab pool).
#   PROD-RELEASE-ENG-07 — the cross-port contract check is no longer a bypassable local-only pre-commit hook;
#                         it is a required, non-bypassable stage of this gate (fail on a removed/changed entry).
#
# Usage:
#   release-gate.sh                     # contract + shellcheck + assembleRelease + lintRelease (the runnable gate)
#   release-gate.sh --contract-only     # fast pre-flight: just the cross-port contract diff
#   release-gate.sh --with-device-smoke # also run the Firebase Test Lab boot-to-first-frame smoke (needs gcloud+pool)
#   release-gate.sh --skip-build        # contract + shellcheck + lint + bridge unit tests (skip the heavy assembleRelease)
#
# Exit: 0 = gate PASS, non-zero = a stage failed (the failing stage is named).
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ANDROID="$ROOT/android"
CONTRACT="$ROOT/tools/shared-contract/check-contract.sh"
CONTRACT_AUTH="$ROOT/tools/shared-contract/check-auth-contract.sh"

run_build=1
run_lint=1
run_device_smoke=0
contract_only=0

for arg in "$@"; do
	case "$arg" in
		--contract-only)     contract_only=1 ;;
		--skip-build)        run_build=0 ;;
		--with-device-smoke) run_device_smoke=1 ;;
		-h|--help)           sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "release-gate: unknown arg '$arg' (see --help)" >&2; exit 64 ;;
	esac
done

hr() { printf '────────────────────────────────────────────────────────────────────────\n'; }
stage() { hr; printf '▶ %s\n' "$1"; hr; }
fail() { echo; echo "✋ GATE FAIL — stage: $1"; exit "${2:-1}"; }

# ── Stage 1: cross-port contract (PROD-RELEASE-ENG-07) ────────────────────────────────────────────────
# Required, non-bypassable. exit 0 = unchanged, 1 = additive-only (OK in CI — the other port simply won't
# call the new entry yet), 2 = a removed/renamed/re-signatured entry that can break the OTHER port.
stage "Contract gate (shared iOS/Android bridge + -D flags)"
set +e
contract_report="$("$CONTRACT" 2>&1)"; contract_rc=$?
set -e
echo "$contract_report"
case "$contract_rc" in
	0) echo "  → contract UNCHANGED." ;;
	1) echo "  → contract ADDITIVE-only (new entry, safe for the other port) — allowed." ;;
	2) fail "contract (a removed/changed entry risks breaking the other port — verify both ports, then refresh baseline.txt)" 2 ;;
	*) fail "contract (check-contract.sh errored, rc=$contract_rc)" "$contract_rc" ;;
esac

# ── Stage 1a: Jagex OAuth wire contract (OAUTH-1) ─────────────────────────────────────────────────────
# Required, non-bypassable. The three login impls (iOS .m / Android .kt / fetch-shield-tokens.sh) mint
# tokens.json in their own runtime BEFORE the JVM boots, so no shared bridge is possible; this checks the
# pinned endpoints / launcher UA / client-ids / scopes / response keys have not drifted across them.
# exit 0 = OK, 2 = drift (a port missing a pinned value).
stage "Jagex OAuth wire contract (iOS / Android / script parity)"
set +e
auth_report="$("$CONTRACT_AUTH" 2>&1)"; auth_rc=$?
set -e
echo "$auth_report"
case "$auth_rc" in
	0) echo "  → auth contract OK." ;;
	2) fail "auth contract (a pinned Jagex OAuth value drifted between ports — reconcile all three, see auth-contract.json)" 2 ;;
	*) fail "auth contract (check-auth-contract.sh errored, rc=$auth_rc)" "$auth_rc" ;;
esac

if [ "$contract_only" -eq 1 ]; then
	echo; echo "✅ contract-only pre-flight PASS."; exit 0
fi

# ── Stage 1b: shellcheck (shell-script lint) ──────────────────────────────────────────────────────────
# Lint every tracked shell script at warning severity (config + the single SC2155 mute in .shellcheckrc).
# Cheap and build-independent, so it runs on every invocation (including --skip-build) except the
# contract-only pre-flight above. --require: the gate is authoritative, so a MISSING shellcheck fails here
# (no silent pass) — unlike the pre-commit hook, which soft-skips an absent optional tool.
stage "shellcheck (tracked shell scripts, --severity=warning)"
"$ROOT/tools/lint/shellcheck.sh" --require || fail "shellcheck (lint findings or shellcheck not installed — see above)"

# ── Stage 1c: ktlint (Kotlin style) ───────────────────────────────────────────────────────────────────
# Lint all tracked Kotlin (config in .editorconfig). --require, like shellcheck, so a missing ktlint fails
# the authoritative gate instead of passing silently.
stage "ktlint (tracked Kotlin)"
"$ROOT/tools/lint/ktlint.sh" --require || fail "ktlint (Kotlin lint findings or ktlint not installed — see above)"

# ── Stage 1d: detekt (Kotlin static analysis) ─────────────────────────────────────────────────────────
# Baseline-gated: existing complexity/exception debt is grandfathered, so this fails only on NEW findings.
stage "detekt (Kotlin static analysis, baseline-gated)"
"$ROOT/tools/lint/detekt.sh" --require || fail "detekt (new Kotlin findings or detekt not installed — see above)"

# ── Stage 1d2: RuneLite api/hub version-pin review (GAP-B-2) ───────────────────────────────────
# runelite.properties pins pluginhub.version + api.base to a version that lags project.build.version (a
# newer minor 404s — commit a310e583c8). That pin is invisible to upstream merges, so this tripwire fails
# the gate when project.build.version advances past the last human-reviewed value in hub-pin.ack, forcing a
# conscious "is the pin still needed?" review. Build-independent, so it runs alongside the linters.
stage "hub-pin review (RuneLite api/hub version drift, GAP-B-2)"
"$ROOT/tools/shared-contract/check-hub-pin.sh" || fail "hub-pin (RuneLite api/hub pin needs review — see above)"

# Gradle is invoked from android/. CI (and most dev shells) already export JAVA_HOME — honour it. Only when it is
# unset do we probe known JDK-21 locations, and only export one that actually exists on disk; if none match (e.g. a
# Linux distro path we don't list), leave JAVA_HOME unset so the gradlew wrapper / PATH `java` resolves it — never
# hard-code a macOS-only path that would point a Linux/Windows run at a non-existent home.
if [ -z "${JAVA_HOME:-}" ]; then
	for cand in \
		/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
		/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home \
		/usr/lib/jvm/temurin-21-jdk-amd64 \
		/usr/lib/jvm/java-21-openjdk-amd64 \
		/usr/lib/jvm/java-21-openjdk
	do
		if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
	done
fi
GRADLEW=(./gradlew --no-daemon --console=plain)

# ── Stage 1e: headless bridge unit tests ──────────────────────────────────────────────────────────────
# Behavioural tests of the shared iOS/Android bridge surface (MenuPeek snapshot JSON + entry fingerprint,
# JavaBridge frame double-buffering + the GPU load-in warmup hold) — coverage the contract signature-diff
# (Stage 1) structurally cannot give: it sees method shapes, not the bytes they emit. Scoped to the
# net.runelite.client.headless package so an unrelated upstream plugin-test breakage never blocks our gate.
# A CORRECTNESS gate, so — like the linters above — it runs on every full invocation and is deliberately NOT
# tied to --skip-build (only --contract-only, which exits before here, skips it). --skip-build still drops
# the heavy assembleRelease/lintRelease/signing; this just costs a :client compile, far cheaper than those.
stage "headless bridge unit tests (:client:test --tests net.runelite.client.headless.*)"
( cd "$ROOT" && "${GRADLEW[@]}" :client:test --tests 'net.runelite.client.headless.*' ) \
	|| fail "headless bridge unit tests"

# ── Stage 2: assembleRelease (PROD-QA-01) ─────────────────────────────────────────────────────────────
# Self-stages the gitignored boot assets via preBuild, then the in-build guards run: verifyNoReleaseSecret
# (no tokens.json session secret in the release artifact) + verifyReleaseBootAssets (JRE + gpu/rlhd jars
# present — an un-bootable APK fails here). A keyless clone falls back to the debug key, so this builds in CI.
if [ "$run_build" -eq 1 ]; then
	stage "assembleRelease (+ verifyNoReleaseSecret / verifyReleaseBootAssets guards)"
	( cd "$ANDROID" && "${GRADLEW[@]}" :app:assembleRelease ) || fail "assembleRelease"
	apk="$ANDROID/app/build/outputs/apk/release/app-release.apk"
	[ -f "$apk" ] || fail "assembleRelease (no app-release.apk emitted)"
	echo "  → built $(cd "$ROOT" && realpath --relative-to="$ROOT" "$apk" 2>/dev/null || echo "$apk") ($(du -h "$apk" | cut -f1))"
fi

# ── Stage 2b: signing verification (PROD-RELEASE-ENG-02) ──────────────────────────────────────────────
# The release artifact must be signed, and when a real release key is configured its certificate MUST
# match the published fingerprint (RELEASE.md "Signing"). A keyless clone/CI falls back to the AOSP debug
# key — allowed but flagged. keystore.properties present yet a non-release cert = hard fail (misconfig).
if [ "$run_build" -eq 1 ]; then
	stage "signing verification (apksigner certificate fingerprint)"
	rel_fp="45e305844d53a6265dc86eb399be997ab3fa2776f90f18b16fd4ec90f43d3c9e"
	dbg_fp="0047cc5876b3f29f0f186154ad6ac705e7a9b2e393238049a471e0730ab25679"
	apksigner="$(command -v apksigner || true)"
	if [ -z "$apksigner" ]; then
		for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
			[ -n "$d" ] || continue
			cand="$(ls -1 "$d"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
			[ -n "$cand" ] && { apksigner="$cand"; break; }
		done
	fi
	[ -n "$apksigner" ] || fail "signing (apksigner not found; install Android build-tools)"
	got_fp="$("$apksigner" verify --print-certs "$apk" 2>/dev/null \
		| awk -F': ' '/SHA-256 digest/{print $2; exit}' | tr -d ' ' | tr 'A-F' 'a-f')"
	[ -n "$got_fp" ] || fail "signing (could not read a certificate from $apk — is it signed?)"
	if [ "$got_fp" = "$rel_fp" ]; then
		echo "  → release-signed ✓ (cert SHA-256 matches RELEASE.md)"
	elif [ "$got_fp" = "$dbg_fp" ]; then
		[ -f "$ANDROID/keystore.properties" ] && fail "signing (keystore.properties present but APK is DEBUG-signed — release key not applied)"
		echo "  → debug-signed (no release key configured — keyless fallback, allowed in CI)"
	else
		fail "signing (UNEXPECTED cert SHA-256 $got_fp — neither the release nor the debug key)"
	fi
fi

# ── Stage 3: lintRelease (PROD-QA-01) ─────────────────────────────────────────────────────────────────
# Android lint aborts on an error severity by default; this is the fail-on-error lint the gate spec asks for.
if [ "$run_lint" -eq 1 ]; then
	stage "lintRelease (fail on error severity)"
	( cd "$ANDROID" && "${GRADLEW[@]}" :app:lintRelease ) || fail "lintRelease"
	echo "  → lint clean (report: android/app/build/reports/lint-results-release.html)"
fi

# ── Stage 4: device smoke (PROD-QA-01, opt-in) ────────────────────────────────────────────────────────
# Boot-to-first-frame on a real GPU. There is no device in plain CI, so this is opt-in and runs the existing
# Firebase Test Lab harness (needs gcloud auth + a configured project). On the operator's machine it is the
# Pixel-7a in-world boot recorded in GATE.md row 2; in a device-pool CI it would be Firebase Robo + :recon.
if [ "$run_device_smoke" -eq 1 ]; then
	stage "device smoke (Firebase Test Lab — boot to first frame)"
	fb="$ANDROID/dev-tools/firebase/fb-gate.sh"
	[ -x "$fb" ] || fail "device-smoke (android/dev-tools/firebase/fb-gate.sh not found/executable)"
	"$fb" || fail "device-smoke"
	echo "  → device smoke PASS."
fi

echo
hr
echo "✅ GATE PASS — Android release gate green."
echo "   contract: rc=$contract_rc  |  shellcheck: ran  |  build: $([ "$run_build" -eq 1 ] && echo assembleRelease || echo skipped)  |  lint: $([ "$run_lint" -eq 1 ] && echo lintRelease || echo skipped)  |  device-smoke: $([ "$run_device_smoke" -eq 1 ] && echo ran || echo 'opt-in (skipped)')"
hr
