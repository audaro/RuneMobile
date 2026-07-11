#!/usr/bin/env bash
#
# Mint a Jagex-account OAuth session for headless RuneLite (Gate 1c-ii).
#
# Walks you through the same OAuth dance the official Jagex Launcher does, then writes the resulting
# session to ios/dev-tools/tokens.json (gitignored). The login harness (run-headless-login.sh) maps that
# file to the JX_* environment variables the real OSRS gamepack reads when "launched from the Jagex
# launcher" — access_token → JX_ACCESS_TOKEN, refresh_token → JX_REFRESH_TOKEN, session_id → JX_SESSION_ID,
# chosen_account_id → JX_CHARACTER_ID, account displayName → JX_DISPLAY_NAME. With those set the gamepack
# mints its own play/OTL token internally, so this script does NOT need to pre-mint one for real RuneLite
# (the otl_token field below is retained only for parity / debugging).
#
# Steps:
#   1. Generate PKCE (verifier + S256 challenge)
#   2. STAGE A (consent flow): produces the id_token game-session accepts → sessionId + account list
#   3. STAGE B (launcher flow, optional): produces access_token / refresh_token for long-session refresh
#   4. Write tokens.json
#
# THROWAWAY Jagex account only — never a main. tokens.json is a secret (mode 600, gitignored).
#
# Sources cross-checked: HyperAlch/microbot-launcher src-tauri/src/jagex_account.rs and
# melxin/native-linux-jagex-launcher src/daemon/game_session.rs.

set -euo pipefail

# ---- Config (matches publicly-known Launcher OAuth clients per melxin/microbot) ----
#
# Two OAuth clients are needed:
#   - LAUNCHER_CLIENT_ID  — code flow w/ PKCE; produces access/refresh tokens for the gamepack
#   - CONSENT_CLIENT_ID   — hybrid (id_token + code) flow; produces the id_token that
#                            game-session API accepts (the launcher client's id_token is
#                            REJECTED by game-session as INVALID_ID_TOKEN; we tested both)
#
# Pinned across all three login impls by tools/shared-contract/auth-contract.json — a change to these
# constants that isn't mirrored to the iOS + Android ports fails check-auth-contract.sh (pre-commit + gate).
LAUNCHER_CLIENT_ID="com_jagex_auth_desktop_launcher"
LAUNCHER_REDIRECT="https://secure.runescape.com/m=weblogin/launcher-redirect"
LAUNCHER_SCOPE="openid offline gamesso.token.create user.profile.read"

CONSENT_CLIENT_ID="1fddee4e-b100-4f4e-b2b0-097f9088f9d2"
CONSENT_REDIRECT="http://localhost"
CONSENT_SCOPE="openid offline"

AUTH_ENDPOINT="https://account.jagex.com/oauth2/auth"
TOKEN_ENDPOINT="https://account.jagex.com/oauth2/token"
# The Host header on game-session/* calls is auth.runescape.com (confirmed by capturing the official Mac
# Launcher with mitmproxy local-mode). auth.jagex.com DNS-resolves to the same Cloudflare backend and has
# tolerated requests, but matching the official Launcher's Host header is safer against fingerprinting.
GAMESESSION_SESSIONS="https://auth.runescape.com/game-session/v1/sessions"
GAMESESSION_ACCOUNTS="https://auth.runescape.com/game-session/v2/accounts?fetchMembership=true"
# OTL (play-token) mint endpoint — POST /game-session/v1/tokens with body {"accountId": "<id>"} + Bearer
# sessionId → {"token": "<53-char play token>"}. Retained for parity; real RuneLite mints its own.
OTL_MINT_ENDPOINT="https://auth.runescape.com/game-session/v1/tokens"

# Mimic a real launcher's User-Agent. Cloudflare is sensitive to UA.
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) JagexLauncher/2.4.4 Chrome/120.0.0.0 Safari/537.36"

OUT_FILE="$(cd "$(dirname "$0")" && pwd)/tokens.json"

# ---- Deps check ----
for cmd in openssl jq curl python3; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

# ---- PKCE generation ----
gen_verifier() {
  # 43-128 chars of [A-Za-z0-9-._~], no padding
  openssl rand -base64 48 | tr -d '\n=' | tr '/+' '_-'
}
gen_challenge() {
  printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64 | tr -d '\n=' | tr '/+' '_-'
}

VERIFIER=$(gen_verifier)
CHALLENGE=$(gen_challenge "$VERIFIER")

# ---- URL-encode helper (python3 to avoid platform shell quirks) ----
urlencode() { python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

# Read a (possibly very long) redirect URL from the user. The consent redirect carries an id_token JWT, so
# the URL is >1024 bytes — and macOS Terminal's canonical input mode caps a single line at MAX_CANON
# (~1024 bytes), silently dropping the rest of the paste AND the Enter keystroke, which makes the prompt
# look frozen. Reading from the clipboard via pbpaste sidesteps the tty limit.
# $1 = human-readable prompt; captured URL is echoed on stdout.
read_url() {
  # A previously-killed interactive run can leave the tty in raw mode (ICRNL off), which makes Enter appear
  # to do nothing. Restore a sane line discipline first.
  stty sane </dev/tty 2>/dev/null || true
  if command -v pbpaste >/dev/null 2>&1; then
    {
      printf '%s\n' "$1"
      printf '  → Copy that URL to your clipboard, then press any key here (do NOT paste): '
    } >/dev/tty
    # read ONE key (not a full line): returns on any byte, so it works even if the tty never translates
    # CR->NL, and a stray paste just consumes one harmless char.
    read -rsn 1 _ </dev/tty || true
    printf '\n' >/dev/tty
    pbpaste | tr -d '\r\n'
  else
    local _typed
    { printf '%s\n' "$1"; printf '  Paste URL here then press Enter: '; } >/dev/tty
    read -r _typed </dev/tty || true
    printf '%s' "$_typed"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#   STAGE A: CONSENT FLOW (OIDC hybrid id_token+code; loopback redirect)
#   Produces the id_token that game-session API accepts.
# ═══════════════════════════════════════════════════════════════════════════════

CONSENT_NONCE=$(openssl rand -base64 36 | tr -d '\n=+/' | head -c 48)
CONSENT_STATE=$(openssl rand -hex 16)

CONSENT_URL="${AUTH_ENDPOINT}?"
CONSENT_URL+="response_type=$(urlencode 'id_token code')"
CONSENT_URL+="&client_id=$CONSENT_CLIENT_ID"
CONSENT_URL+="&redirect_uri=$(urlencode "$CONSENT_REDIRECT")"
CONSENT_URL+="&scope=$(urlencode "$CONSENT_SCOPE")"
CONSENT_URL+="&nonce=$CONSENT_NONCE"
CONSENT_URL+="&state=$CONSENT_STATE"

cat <<EOF

═══════════════════════════════════════════════════════════════════════════════
  STAGE A: CONSENT FLOW (1 of 2 browser logins)
═══════════════════════════════════════════════════════════════════════════════

Open this URL in Safari and log in with the THROWAWAY account:

$CONSENT_URL

The browser will fail to load http://localhost (no server) — that's expected.
Copy the URL from the address bar. It uses # (fragment) not ? (query):

  http://localhost/#id_token=eyJ...&code=...&state=$CONSENT_STATE

Paste it back below.

═══════════════════════════════════════════════════════════════════════════════

EOF
CONSENT_RAW="$(read_url "Paste the CONSENT redirect URL (the http://localhost/#id_token=... one):")"

# Extract id_token from URL fragment
CONSENT_ID_TOKEN=$(printf '%s' "$CONSENT_RAW" | python3 -c "
import sys, urllib.parse
raw = sys.stdin.read().strip()
parsed = urllib.parse.urlparse(raw)
# Hybrid flow returns id_token in fragment, not query
fragment = parsed.fragment
qs = urllib.parse.parse_qs(fragment)
print(qs.get('id_token', [''])[0])
")
if [[ -z "$CONSENT_ID_TOKEN" ]]; then
  echo "ERROR: no id_token in consent fragment. Pasted: $CONSENT_RAW" >&2
  exit 1
fi
echo "✓ Got consent id_token (length=${#CONSENT_ID_TOKEN})"

# ---- Game session enumeration (now works because we have the consent id_token) ----
echo
echo "Fetching game session at $GAMESESSION_SESSIONS ..."
SESSION_RESPONSE=$(curl -sS --max-time 20 --connect-timeout 10 -X POST "$GAMESESSION_SESSIONS" \
  -H "Content-Type: application/json" \
  --data "$(jq -n --arg t "$CONSENT_ID_TOKEN" '{idToken: $t}')")

SESSION_ID=""
ACCOUNTS_JSON="[]"
if echo "$SESSION_RESPONSE" | jq -e 'has("sessionId")' >/dev/null 2>&1; then
  SESSION_ID=$(echo "$SESSION_RESPONSE" | jq -r .sessionId)
  echo "✓ Got sessionId (length=${#SESSION_ID})"

  ACCOUNTS_RESPONSE=$(curl -sS --max-time 20 --connect-timeout 10 "$GAMESESSION_ACCOUNTS" \
    -H "Authorization: Bearer $SESSION_ID" -H "Accept: application/json")

  if echo "$ACCOUNTS_RESPONSE" | jq -e 'type == "array"' >/dev/null 2>&1; then
    ACCOUNTS_JSON="$ACCOUNTS_RESPONSE"
    NUM_ACCOUNTS=$(echo "$ACCOUNTS_JSON" | jq 'length')
    echo "✓ Got $NUM_ACCOUNTS game account(s):"
    echo "$ACCOUNTS_JSON" | jq -r '.[] | "  - displayName=\(.displayName // "<none>") accountId=\(.accountId)"'
  fi
else
  echo "WARN: game-session call did not return sessionId:"
  echo "$SESSION_RESPONSE" | jq . 2>/dev/null || echo "$SESSION_RESPONSE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#   STAGE B: LAUNCHER FLOW (standard code flow + PKCE; weblogin redirect)
#   Produces access_token / refresh_token / id_token for the gamepack requesters.
# ═══════════════════════════════════════════════════════════════════════════════

AUTH_URL="${AUTH_ENDPOINT}?"
AUTH_URL+="auth_method=&login_type=&flow=launcher"
AUTH_URL+="&response_type=code"
AUTH_URL+="&client_id=$(urlencode "$LAUNCHER_CLIENT_ID")"
AUTH_URL+="&redirect_uri=$(urlencode "$LAUNCHER_REDIRECT")"
AUTH_URL+="&code_challenge=$(urlencode "$CHALLENGE")"
AUTH_URL+="&code_challenge_method=S256"
AUTH_URL+="&prompt=login"
AUTH_URL+="&scope=$(urlencode "$LAUNCHER_SCOPE")"
AUTH_URL+="&state=$(urlencode "$VERIFIER")"

cat <<EOF

═══════════════════════════════════════════════════════════════════════════════
  STAGE B: LAUNCHER FLOW (2 of 2 browser logins)
  Should be near-silent in the same Safari (consent cookies are warm).
═══════════════════════════════════════════════════════════════════════════════

Open in Safari:

$AUTH_URL

Browser will fail to load secure.runescape.com — copy the URL containing ?code=...

═══════════════════════════════════════════════════════════════════════════════

EOF
# Stage B is OPTIONAL: the launcher access/refresh tokens it produces feed the gamepack's long-session
# *refresh* path (JX_ACCESS_TOKEN / JX_REFRESH_TOKEN). Initial login + render works off Stage A's
# session_id + chosen account alone (the gamepack mints its own play token from JX_SESSION_ID +
# JX_CHARACTER_ID). So if you can't capture the launcher ?code= URL, we still write a usable tokens.json.
#
# Read + extract the launcher 'code'. The Stage A consent URL also contains a code= (in its fragment) but
# it's issued to the consent client, so reusing it fails the exchange with invalid_grant — reject any URL
# carrying id_token=.
ACCESS_TOKEN=""; REFRESH_TOKEN=""; ID_TOKEN=""; EXPIRES_IN=0; SCOPE_GRANTED=""
CODE=""; REDIRECT_RAW=""
for _try in 1 2 3 4 5; do
  REDIRECT_RAW="$(read_url "Paste the LAUNCHER redirect URL (secure.runescape.com/...?code=...):")"
  REDIRECT_CLEAN="${REDIRECT_RAW#jagex:}"   # strip Jagex's custom prefix if present
  # If the clipboard is still the Stage A consent URL (unchanged), don't loop 5x — skip Stage B straight
  # away and keep the (sufficient) Stage A tokens.
  if [[ "$REDIRECT_RAW" == "$CONSENT_RAW" ]]; then
    echo "  Clipboard is still the Stage A URL — skipping the optional Stage B." >&2
    CODE=""; break
  fi
  if printf '%s' "$REDIRECT_CLEAN" | grep -q 'id_token='; then
    echo "  ✗ That's the STAGE A consent URL (it contains id_token=). (try $_try/5)" >&2
    echo "    For Stage B: open the launcher URL above in Safari, then copy the" >&2
    echo "    secure.runescape.com/...?code=... URL it fails to load — re-copy, press a key." >&2
    CODE=""; continue
  fi
  # launcher flow returns ?code=... in the query (melxin also sees comma-separated)
  CODE=$(printf '%s' "$REDIRECT_CLEAN" | python3 -c "
import sys, urllib.parse
raw = sys.stdin.read().strip().replace(',', '&')
p = urllib.parse.urlparse(raw)
print(urllib.parse.parse_qs(p.query if p.query else raw.split('?', 1)[-1]).get('code', [''])[0])
")
  [[ -n "$CODE" ]] && break
  echo "  ✗ No 'code' found in that URL. Re-copy + press a key. (try $_try/5)" >&2
done

if [[ -z "$CODE" ]]; then
  echo
  echo "WARN: skipping Stage B (no launcher code). tokens.json will have empty" >&2
  echo "      access/refresh tokens — initial login still works via session_id," >&2
  echo "      but long-session token refresh won't. Re-run later to add them." >&2
else
  echo
  echo "Extracted authorization code (length=${#CODE})."
  echo "Exchanging for tokens at $TOKEN_ENDPOINT ..."
  TOKEN_RESPONSE=$(curl -sS --max-time 20 --connect-timeout 10 -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    -H "User-Agent: $USER_AGENT" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "client_id=$LAUNCHER_CLIENT_ID" \
    --data-urlencode "code=$CODE" \
    --data-urlencode "code_verifier=$VERIFIER" \
    --data-urlencode "redirect_uri=$LAUNCHER_REDIRECT")
  if echo "$TOKEN_RESPONSE" | jq -e 'has("access_token")' >/dev/null 2>&1; then
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .access_token)
    REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .refresh_token)
    ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .id_token)
    EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // 0')
    SCOPE_GRANTED=$(echo "$TOKEN_RESPONSE" | jq -r .scope)
    echo "✓ Got launcher tokens (access expires in ${EXPIRES_IN}s, scope=\"$SCOPE_GRANTED\")"
  else
    echo "WARN: launcher token exchange failed — continuing with Stage A tokens only. Response:" >&2
    echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$TOKEN_RESPONSE" >&2
  fi
fi

# ---- Mint OTL (play) token via POST /game-session/v1/tokens (parity / debugging only) ----
# Real RuneLite mints its own play token from JX_SESSION_ID + JX_CHARACTER_ID, so this is not required for
# the headless login harness; kept so tokens.json mirrors what the official Launcher produces. The OTL
# token is short-lived (~1-2 min).
OTL_TOKEN=""
if [[ -n "$SESSION_ID" ]] && [[ "$(echo "$ACCOUNTS_JSON" | jq 'length')" -gt 0 ]]; then
  CHOSEN_ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].accountId')
  CHOSEN_ACCOUNT_NAME=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].displayName // "<no displayName>"')
  echo
  echo "Minting OTL token for accountId=$CHOSEN_ACCOUNT_ID ($CHOSEN_ACCOUNT_NAME) ..."
  OTL_RESPONSE=$(curl -sS --max-time 20 --connect-timeout 10 -X POST "$OTL_MINT_ENDPOINT" \
    -H "Authorization: Bearer $SESSION_ID" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "User-Agent: $USER_AGENT" \
    --data "$(jq -n --arg a "$CHOSEN_ACCOUNT_ID" '{accountId: $a}')")
  if echo "$OTL_RESPONSE" | jq -e 'has("token")' >/dev/null 2>&1; then
    OTL_TOKEN=$(echo "$OTL_RESPONSE" | jq -r .token)
    echo "✓ Got OTL play token (length=${#OTL_TOKEN})"
  else
    echo "WARN: OTL mint did not return {\"token\": ...}. Raw response:"
    echo "$OTL_RESPONSE" | jq . 2>/dev/null || echo "$OTL_RESPONSE"
  fi
else
  echo
  echo "SKIP: cannot mint OTL — no sessionId or no game accounts. (Did Stage A fail?)"
fi

# ---- Write tokens to ios/dev-tools/tokens.json (gitignored) ----
jq -n \
  --arg access "$ACCESS_TOKEN" \
  --arg refresh "$REFRESH_TOKEN" \
  --arg id "$ID_TOKEN" \
  --argjson exp "$EXPIRES_IN" \
  --arg scope "$SCOPE_GRANTED" \
  --arg session "$SESSION_ID" \
  --argjson accounts "$ACCOUNTS_JSON" \
  --arg otl "$OTL_TOKEN" \
  --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    access_token: $access,
    refresh_token: $refresh,
    id_token: $id,
    expires_in: $exp,
    scope: $scope,
    session_id: $session,
    accounts: $accounts,
    otl_token: $otl,
    fetched_at: $fetched_at,
    chosen_account_id: ($accounts | if length > 0 then .[0].accountId else "" end),
    chosen_display_name: ($accounts | if length > 0 then (.[0].displayName // "") else "" end),
    notes: "Headless RuneLite (Gate 1c-ii) login session. run-headless-login.sh maps: access_token->JX_ACCESS_TOKEN, refresh_token->JX_REFRESH_TOKEN, session_id->JX_SESSION_ID, chosen_account_id->JX_CHARACTER_ID, chosen_display_name->JX_DISPLAY_NAME. The gamepack mints its own play token from JX_SESSION_ID+JX_CHARACTER_ID, so otl_token is not required here (parity only)."
  }' > "$OUT_FILE"
chmod 600 "$OUT_FILE"

cat <<EOF

═══════════════════════════════════════════════════════════════════════════════
  ✓ Tokens written to:  $OUT_FILE
  File mode:            600 (owner read/write only)
  REMINDER: tokens.json is gitignored — never commit it.
═══════════════════════════════════════════════════════════════════════════════

Next: run the headless login harness to map these to JX_* env vars and observe
whether the client reaches LOGGED_IN:

  ios/dev-tools/headless/run-headless-login.sh          # native toolkit
  ios/dev-tools/headless/run-headless-login-cacio.sh    # CACIO, no OS window

EOF
