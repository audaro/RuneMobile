#!/usr/bin/env bash
#
# macbook-transition.sh — one-shot setup on the MacBook to continue the iOS GPU device-kit work.
# Pulls the latest code (origin/gpu) + the local-only state bundle (tokens / JRE / cacio jars / project memory)
# from the Mac mini over Tailscale, rebuilds the gitignored jars, regenerates the Xcode project (EAGL backend),
# compiles + (if a phone is attached) installs the app. Idempotent — safe to re-run.
#
# RUN ON THE MACBOOK:
#   scp youruser@<source-mac-tailnet-ip>:macbook-transition.sh /tmp/t.sh && bash /tmp/t.sh
#
# Overridable via env: MINI, MINI_USER, REPO, BRANCH, JAVA_HOME, SKIP_BUNDLE=1 (skip the 91MB transfer if state present).

set -uo pipefail

MINI="${MINI:-100.100.100.100}"              # source Mac tailnet IP
MINI_USER="${MINI_USER:-youruser}"
BUNDLE_NAME="${BUNDLE_NAME:-runelite-ios-local-state.tar.gz}"
ORIGIN="${ORIGIN:-git@github.com:YOUR_USER/YOUR_REPO.git}"
REPO="${REPO:-$HOME/runelite-ios}"
BRANCH="${BRANCH:-gpu}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
CONFIG="${CONFIG:-Debug}"                     # Debug (default dev bootstrap) | Release (hardened, QA-P1-12/13)
case "$CONFIG" in Debug|Release) ;; *) echo "CONFIG must be Debug or Release (got '$CONFIG')" >&2; exit 1 ;; esac
export JAVA_HOME

SSHO=(-o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new)

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
run()  { "$@" || die "step failed: $* (see output above)"; }

# ---------------------------------------------------------------------------
say "0/7  Preflight (toolchain)"
command -v git        >/dev/null || die "git missing"
command -v xcodebuild >/dev/null || die "xcodebuild missing — install Xcode, then: xcode-select --install"
command -v xcodegen   >/dev/null || { warn "xcodegen missing — installing via Homebrew"; run brew install xcodegen; }
[ -x "$JAVA_HOME/bin/java" ] || die "no java at JAVA_HOME=$JAVA_HOME  (brew install openjdk@21, or set JAVA_HOME=...)"
ok "git / xcodebuild / xcodegen / java ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | tr -d '"'))"

# ---------------------------------------------------------------------------
say "1/7  Reachability — $MINI_USER@$MINI over Tailscale"
ssh "${SSHO[@]}" "$MINI_USER@$MINI" true 2>/dev/null \
  || die "can't ssh $MINI_USER@$MINI. Wake the mini and enable Remote Login (System Settings ▸ General ▸ Sharing ▸ Remote Login), or set MINI=<tailnet ip>."
ok "ssh to the mini works"

# ---------------------------------------------------------------------------
say "2/7  Repo — $REPO @ origin/$BRANCH"
if [ ! -d "$REPO/.git" ]; then warn "no clone at $REPO — cloning"; run git clone "$ORIGIN" "$REPO"; fi
cd "$REPO" || die "cannot cd $REPO"
run git fetch --quiet origin
# preserve anything local before fast-forwarding to the mini's pushed state
if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
  S="transition-$(date +%s)"
  git stash push --include-untracked -m "$S" >/dev/null 2>&1 && warn "local changes stashed as '$S' (recover with: git stash list)"
fi
git checkout -q "$BRANCH" 2>/dev/null || run git checkout -q -b "$BRANCH" "origin/$BRANCH"
run git reset --hard "origin/$BRANCH"
ok "at $(git rev-parse --short HEAD) — $(git log -1 --format=%s | cut -c1-64)"

# ---------------------------------------------------------------------------
say "3/7  Local-only state (tokens / JRE / cacio jars / memory)"
NEED=0
[ -f ios/dev-tools/tokens.json ] && [ -d ios/dev-tools/jre ] && [ -d ios/dev-tools/cacio-smoke/lib ] || NEED=1
if [ "${SKIP_BUNDLE:-0}" = 1 ] && [ "$NEED" = 0 ]; then
  ok "essentials present; SKIP_BUNDLE=1 → skipping the bundle transfer"
else
  TMPB="/tmp/$BUNDLE_NAME"
  warn "pulling $BUNDLE_NAME from the mini (~91 MB)…"
  run scp "${SSHO[@]}" "$MINI_USER@$MINI:$BUNDLE_NAME" "$TMPB"
  if scp "${SSHO[@]}" "$MINI_USER@$MINI:$BUNDLE_NAME.sha256" "$TMPB.sha256" 2>/dev/null; then
    GOT=$(shasum -a 256 "$TMPB" | awk '{print $1}'); WANT=$(tr -d '[:space:]' < "$TMPB.sha256")
    [ "$GOT" = "$WANT" ] || die "bundle checksum mismatch (got $GOT, want $WANT) — re-run package-local-state.sh on the mini"
    ok "bundle verified ($GOT)"
  else
    warn "no checksum sidecar on the mini — skipping integrity check"
  fi
  rm -rf /tmp/rl-bundle && mkdir -p /tmp/rl-bundle && run tar xzf "$TMPB" -C /tmp/rl-bundle
  ( cd "$REPO" && /tmp/rl-bundle/unpack-local-state.sh /tmp/rl-bundle ) || die "unpack-local-state.sh failed"
  ok "installed tokens / JRE / cacio jars + refreshed project memory"
fi

# ---------------------------------------------------------------------------
say "4/7  Build the gitignored jars (client → iOS-GPU-stage → probes → l1)"
run ./gradlew -q :client:shadowJar;                                              ok "shaded client jar"
( cd ios/dev-tools/gpu-routec && ./stage-ios-gpu-jar.sh ) >/tmp/rl-stage.log 2>&1 || die "stage-ios-gpu-jar failed (tail /tmp/rl-stage.log)"; ok "staged iOS GPU jar"
( cd ios/app && ./build-probes.sh ) >/tmp/rl-probes.log 2>&1 || die "build-probes failed (tail /tmp/rl-probes.log)";                      ok "probes.jar"
( cd ios/dev-tools/gpu-routec/l1 && ./build-l1-probe.sh ) >/tmp/rl-l1.log 2>&1   || die "build-l1-probe failed (tail /tmp/rl-l1.log)";    ok "routec-l1.jar"

# ---------------------------------------------------------------------------
say "5/7  Generate the Xcode project (EAGL backend)"
( cd ios/app && xcodegen generate >/dev/null ) || die "xcodegen failed"
ok "RuneMobile.xcodeproj"

# ---------------------------------------------------------------------------
say "6/7  Bridge arm64 compile-check"
bash ios/dev-tools/gpu-routec/routec-device-compile-check.sh 2>&1 | grep -E 'OK |FAIL|MEGAVERDICT' || warn "compile-check produced no verdict line"

# ---------------------------------------------------------------------------
say "7/7  Build the app ($CONFIG) + install if a phone is attached"
run xcodebuild -project ios/app/RuneMobile.xcodeproj -scheme RuneMobile -configuration "$CONFIG" \
  -destination "generic/platform=iOS" -derivedDataPath build/dd-gpu -allowProvisioningUpdates build
APP="build/dd-gpu/Build/Products/${CONFIG}-iphoneos/RuneMobile.app"
ok "built $APP"
DEV=$(xcrun devicectl list devices 2>/dev/null | grep -iE 'iphone' | grep -ioE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}|[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
if [ -n "${DEV:-}" ]; then
  if xcrun devicectl device install app --device "$DEV" "$APP" >/tmp/rl-install.log 2>&1; then
    ok "installed to device $DEV"
  else
    warn "install failed (USB cable / Trust this computer?) — see /tmp/rl-install.log; install manually per DEVICE-KIT.md"
  fi
else
  warn "no iPhone over USB. Connect + Trust, then: xcrun devicectl device install app --device <uuid> $REPO/$APP"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1;32m================  READY  ================\033[0m\n'
cat <<EOF
On origin/$BRANCH ($(git -C "$REPO" rev-parse --short HEAD)), EAGL build, app built$([ -n "${DEV:-}" ] && echo " + installed").

Next — the gl_FragDepth early-Z A/B (full steps: ios/dev-tools/gpu-routec/DEVICE-KIT.md):
  1) push mode=baseline, attach StikDebug, Run GPU, walk to the Grand Exchange, stand still ~60s
  2) push mode=fragdepth, Run GPU, same spot, ~60s
  3) pull Documents/routec-perf.log and compare 'gpuFinish avg/p95' between the two lines
  (push a mode:  printf MODE > /tmp/mode.txt; xcrun devicectl device copy to --device <uuid> \\
     --domain-type appDataContainer --domain-identifier dev.audaro.runemobile \\
     --source /tmp/mode.txt --destination Documents/routec-water-mode.txt )

If OSRS login fails, the Jagex tokens are stale — re-mint: ios/dev-tools/fetch-shield-tokens.sh
EOF
