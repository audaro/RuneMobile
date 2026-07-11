#!/usr/bin/env bash
# One-shot Firebase Test Lab setup — minimize manual work. It installs the Google Cloud SDK (gcloud) if missing,
# guides the SINGLE browser sign-in, picks (or creates) a FREE Spark-plan project (no billing), enables the
# Cloud Testing APIs, and verifies a real device is reachable. Idempotent — safe to re-run any time.
#
#   THE ONLY MANUAL STEP IS SIGNING IN WITH YOUR GOOGLE ACCOUNT (a browser opens once).
#
# After this succeeds:  ./fb-gate.sh login   # runs the app on a REAL device (boot -> autologin -> LOGGED_IN)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }

# ---- 1. gcloud SDK ------------------------------------------------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
  # The cask may already be installed but not yet on PATH this shell — try to source it first.
  for inc in "$(brew --prefix 2>/dev/null)/share/google-cloud-sdk/path.bash.inc" \
             "/opt/homebrew/share/google-cloud-sdk/path.bash.inc"; do
    # shellcheck source=/dev/null
    [ -f "$inc" ] && . "$inc" && break
  done
fi
if ! command -v gcloud >/dev/null 2>&1; then
  step "Installing the Google Cloud SDK (gcloud) via Homebrew — one-time, ~200MB"
  command -v brew >/dev/null 2>&1 || { warn "Homebrew not found. Install it from https://brew.sh then re-run this."; exit 1; }
  brew install --cask google-cloud-sdk
  for inc in "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" "/opt/homebrew/share/google-cloud-sdk/path.bash.inc"; do
    # shellcheck source=/dev/null
    [ -f "$inc" ] && . "$inc" && break
  done
  hash -r 2>/dev/null || true
fi
command -v gcloud >/dev/null 2>&1 || { warn "gcloud installed but not on PATH. Open a NEW terminal and re-run this script."; exit 1; }
ok "gcloud: $(gcloud --version 2>/dev/null | head -1)"

# ---- 2. sign in (the only manual step) ---------------------------------------------------------------------
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  step "Sign in with your Google account"
  echo "A browser window will open. Pick your Google account and allow access. (This is the ONLY manual step.)"
  read -r -p "Press Enter to open the sign-in… " _ || true
  gcloud auth login
fi
ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
ok "signed in as $ACCOUNT"

# ---- 3. project (use configured, else an existing one, else create a free one) -----------------------------
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
  EXISTING="$(gcloud projects list --format='value(projectId)' --limit=1 2>/dev/null | head -1 || true)"
  if [ -n "$EXISTING" ]; then
    PROJECT="$EXISTING"
    ok "using your existing project: $PROJECT"
  else
    PROJECT="rl-android-$(date +%y%m%d%H%M)"
    step "Creating a free project: $PROJECT (no billing — Test Lab Spark is free)"
    gcloud projects create "$PROJECT" --name="RuneLite Android Test Lab" \
      || { warn "Project create failed. Create one (free) at https://console.cloud.google.com/projectcreate then re-run: gcloud config set project <ID> && $0"; exit 1; }
  fi
  gcloud config set project "$PROJECT" >/dev/null
fi
ok "project: $PROJECT"

# ---- 4. enable the (free) Cloud Testing APIs ---------------------------------------------------------------
step "Enabling the Cloud Testing APIs (free, no billing for the Spark tier)"
if gcloud services enable testing.googleapis.com toolresults.googleapis.com --project "$PROJECT" 2>/tmp/fb-enable-err; then
  ok "APIs enabled"
else
  warn "Could not enable the testing APIs automatically:"; cat /tmp/fb-enable-err >&2
  warn "These two APIs are free (no billing needed). Enable them once in the console, then re-run:"
  warn "  https://console.cloud.google.com/apis/library/testing.googleapis.com?project=$PROJECT"
  warn "  https://console.cloud.google.com/apis/library/toolresults.googleapis.com?project=$PROJECT"
fi

# ---- 5. verify a real device is reachable ------------------------------------------------------------------
step "Verifying Test Lab access — a few real (PHYSICAL) devices you can target"
if gcloud firebase test android models list --filter=form=PHYSICAL \
     --format='table(id,name,supportedVersionIds.list())' 2>/tmp/fb-models-err | head -18; then
  echo
  ok "Firebase Test Lab is READY."
  echo "Next:"
  echo "  cd $HERE/../.. && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug"
  echo "  $HERE/fb-gate.sh login          # run the app on a REAL device: boot -> autologin -> LOGGED_IN"
else
  warn "Could not list devices:"; cat /tmp/fb-models-err >&2
  if grep -qiE "firebase|not.*enabled|PERMISSION_DENIED" /tmp/fb-models-err; then
    warn "If it says the project isn't Firebase-enabled: add Firebase (free, 2 clicks) at"
    warn "  https://console.firebase.google.com  ->  Add project  ->  pick the existing '$PROJECT'  ->  (skip Analytics)"
    warn "then re-run this script."
  fi
  exit 1
fi
