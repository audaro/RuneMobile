# Cross-port shared-contract guard

iOS and Android embed the **same staged jars** and call into them by name (JNI/reflection). The only thing that
couples the two ports is that **host-facing contract**: the public-static API of the `net.runelite.client.headless.*`
bridges, the two boot/activation entry points the native hosts invoke (`DeviceHeadlessBoot.main`,
`UnsafePokeActivation.activate`), and the `-D` gate/property names those classes read. A change there can break the
*other* port even though none of its own files were touched.

This guard makes such changes impossible to miss.

## Pieces
- **`extract-contract.py`** — extracts the contract from source as sorted `METHOD …` / `FLAG …` lines (param
  names stripped, so only real signatures count).
- **`baseline.txt`** — the committed snapshot of the contract.
- **`check-contract.sh`** — diffs current vs baseline. Exit `0` unchanged, `1` additive-only, `2` removed/changed.
  `--update` rewrites the baseline.
- **`../git-hooks/pre-commit`** — on every commit: if staged files feed the shared jars (`runelite-client/`,
  `ios/dev-tools/awtsmoke/`, `tools/stage-*.sh`) it prints a flag; if the contract drifted it **blocks** until you
  stage a refreshed `baseline.txt` (your acknowledgement that you checked the other port).

## Install (once per clone — do this on every machine)
```
tools/git-hooks/install.sh        # sets core.hooksPath = tools/git-hooks
```

## When the hook blocks you
The contract changed. Decide if it's safe for the other port, then:
```
# 1. verify the OTHER port still satisfies the new contract
./android/dev-tools/bridge-census/run-census-desktop.sh     # Android: expect GREEN
#   iOS: rebuild the client jar + run the iOS bridge checks

# 2. acknowledge by refreshing + staging the baseline, then re-commit
./tools/shared-contract/check-contract.sh --update
git add tools/shared-contract/baseline.txt
```
Additive changes (a new bridge method) are safe — the other port just won't call it yet — but you still stage the
baseline so it stays truthful. Removed/renamed/re-signatured entries are the real danger and are called out
explicitly. Emergency bypass: `git commit --no-verify`.

## Promoted to a required gate stage (PROD-RELEASE-ENG-07)
`check-contract.sh` is no longer *only* the bypassable local pre-commit hook. It is a **required, non-bypassable
stage of the Android release gate** — `android/dev-tools/ci/release-gate.sh` runs it first and **fails on exit 2**
(a removed/renamed/re-signatured entry that risks breaking the other port). The dormant-but-ready
`.github/workflows/android-release-gate.yml` calls the same script, so when GitHub Actions are enabled the
contract check runs there too. The pre-commit hook stays as the fast local pre-flight. See `android/GATE.md` row 6.

## What it does and doesn't guarantee
It catches contract **drift** at commit/gate time and forces a conscious cross-port check — it does not itself
build both apps. The actual "doesn't break the other port" proof is the Android bridge census (and the iOS bridge
checks) it tells you to run; this guard makes sure you never forget to.

## Sibling guard: the Jagex OAuth wire contract (OAUTH-1)
The login path is **not** part of the jar contract above — it runs entirely in native code (iOS `NSURLSession`,
Android `HttpURLConnection`) and mints `tokens.json` **before the JVM boots**, so it can never route through a
shared JVM-side bridge. Instead the same OAuth wire constants are re-implemented in three places:

- `ios/app/RuneMobile/JagexLoginViewController.m` (Stage-A consent → session → accounts)
- `android/app/src/main/java/dev/audaro/runemobile/JagexLogin.kt` (same)
- `ios/dev-tools/fetch-shield-tokens.sh` (the full flow incl. Stage-B launcher tokens + OTL mint)

- **`auth-contract.json`** — the single source of truth: every endpoint, the Cloudflare-sensitive launcher
  User-Agent, both client ids, scopes, the consent `response_type`, the PKCE method, and the Jagex request/response
  keys, each tagged with the `ports` that must carry it.
- **`check-auth-contract.py` / `check-auth-contract.sh`** — assert every pinned value is present in each listed
  port (whitespace-collapsed; the wrapped launcher UA is pinned as two per-line fragments). Exit `0` clean, `2` on
  drift, naming the exact `[port] pin: value` that diverged.

Wired in the same two places as the jar guard: the **pre-commit hook** blocks when a staged login change drifts a
pinned value, and the **release gate** runs it as required Stage 1a (`--contract-only` covers it too). Editing
`auth-contract.json` *is* the acknowledgement — there is no separate baseline to stage. When Jagex changes a value,
update the JSON **and every listed port in the same commit**.
