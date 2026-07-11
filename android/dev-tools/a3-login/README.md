# A3 — on-device Jagex login (WebView OAuth)

Log in on the phone with no desktop — the Android twin of the iOS `JagexLoginViewController`. A `WebView` runs
the **Stage-A OAuth consent flow**, the loopback redirect is intercepted for its `id_token`, and `id_token` →
game session → character list → `tokens.json`. Then `JagexTokens` (A0) maps `tokens.json` → the `JX_*` env the
gamepack reads, and autologin reaches LOGGED_IN.

## Files

- **`JagexLogin.kt`** — the OAuth logic (ported verbatim from `ios/dev-tools/fetch-shield-tokens.sh` +
  `JagexLoginViewController.m`): consent URL, `id_token` extraction, `mintSession` (POST
  `auth.runescape.com/game-session/v1/sessions`), `fetchAccounts` (GET `.../v2/accounts`), `writeTokens`
  (filesDir `tokens.json`). All HTTP carries the **launcher User-Agent** (Cloudflare is UA-sensitive).
- **`LoginActivity.kt`** — the WebView + `shouldOverrideUrlLoading` (catch `http://localhost/#id_token=…`) +
  character-picker dialog. Cookies are cleared first (ephemeral session → account switching works). On a
  chosen character it writes `tokens.json` and **restarts the process** so the next boot snapshots `JX_*` at
  `JNI_CreateJavaVM` (the Review-2 login-first-boot rule).
- **`MainActivity`** — the **login-first boot gate** (no `tokens.json` → launch login before booting) + a `⎆`
  sign-in / switch-account button.

## OAuth constants (Stage A, verbatim from the proven iOS flow)

```
auth      https://account.jagex.com/oauth2/auth   response_type=id_token+code  scope=openid offline
client_id 1fddee4e-b100-4f4e-b2b0-097f9088f9d2    redirect_uri=http://localhost (loopback, intercepted)
sessions  POST https://auth.runescape.com/game-session/v1/sessions   {idToken} -> {sessionId}
accounts  GET  https://auth.runescape.com/game-session/v2/accounts?fetchMembership=true   Bearer sessionId
```

## Verification

The end-to-end login is **interactive / user-only** (real Jagex creds, throwaway account) per the project auth
rule — there is no automated md5 gate for it. What is verified emulator-side (no creds):

- **Build** — `:app:assembleDebug` clean.
- **Login-first gate** — with `tokens.json` present the gate skips and the game boots (no `a3: no tokens.json`,
  `startJvm rc=0`); with none it launches `LoginActivity`.
- **WebView loads the genuine Jagex OAuth page** — `LoginActivity` opens (`⎆` button / gate), the WebView
  reaches `account.jagex.com/oauth2/auth` and renders the real consent flow (Cloudflare "Are you a robot?"
  human-check, then the login form) — see `evidence-login-webview.png`. Confirms the launcher-UA WebView is
  accepted and the redirect-interception harness is in place.

### User-driven end-to-end (the remaining leg)

1. Launch the app with **no** `tokens.json` (fresh install) → the login appears automatically; or tap `⎆`.
2. Solve the Cloudflare check, log in with the **throwaway** account, pick a character.
3. The app writes `tokens.json` + restarts → autologin should reach LOGGED_IN (watch `gameState … LOGGED_IN`,
   `ANDROID_A6_UI_GREEN`). GREEN = a fresh on-device login (no pushed tokens) renders in-world.
