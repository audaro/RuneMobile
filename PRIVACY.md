# Privacy & data flow

> Unofficial fan project. Not affiliated with, endorsed by, or sponsored by Jagex or the
> RuneLite project. This document describes exactly what data the app handles, where it is
> stored, and what leaves the device. It applies to both ports (Android and iOS); the data
> model is shared, only the on-device storage paths differ by platform.

## Summary

- **There is no first-party server and no analytics.** The maintainer operates no backend and
  receives **no** data about you or your usage.
- **Your personal/account data** goes only to **Jagex** (to play the game) and, **only if you
  choose to sign in**, to the **RuneLite project** (to sync your config and hub plugins).
- **The client also makes a few standard, non-opt-in network fetches that carry no account data** —
  to **Jagex** (the game-launcher config) and to **RuneLite's CDN/API** (a runtime config blob and
  the world list). Like any web request these reveal your device's IP to those hosts, but send no
  personal payload. They are itemised in the table below.
- **No telemetry or crash reports are sent.** This build boots the embedded client with
  `--disable-telemetry`, so RuneLite's usual boot telemetry and JVM-crash reporting to
  `api.runelite.net` are **off**.
- **RuneLite's crowdsourced-data uploads are also off in this build.** Stock RuneLite pings a session
  heartbeat and, via default-on plugins, uploads loot drops, kill-count chat data, and Grand Exchange
  offer events (the last with a machine fingerprint) to `api.runelite.net`. In this build the session
  ping is disabled, GE offer uploads are removed, and **Loot Tracker and Chat Commands ship disabled**
  — if you enable those two plugins, their uploads work exactly as on desktop RuneLite (see the table
  below).
- **Your credentials stay on the device.** OAuth tokens live in app-private storage and are sent
  only to the service that issued them (Jagex). No release build ships a login token.
- **Everything the app stores locally** (game cache, settings, renderer choice, diagnostics) stays
  on the device unless a row below says otherwise.

## What leaves the device

**Carries your account/personal data:**

| Data | What it is | Sent to | When | Your control |
|---|---|---|---|---|
| Jagex OAuth (`id_token` → `session_id`) | The login handshake that proves you own the account | `account.jagex.com`, `auth.runescape.com` | When you log in | Log in / log out |
| Game traffic | The live OSRS protocol (movement, actions, world state) | Jagex game servers (`oldschool*.runescape.com`) | While in-world | Log out / close app |
| RuneLite account sync | Your RuneLite profiles, plugin settings, and installed hub plugins | `api.runelite.net` | **Only if** you sign into a RuneLite account in the plugins panel | Opt-in; sign out to stop |
| Loot Tracker uploads | Loot drops you receive (npc/event, items) — RuneLite's crowdsourced loot database; sent even without a RuneLite account, tied to one if signed in | `api.runelite.net` | **Only if** you enable the Loot Tracker plugin (**off by default** in this build) | Opt-in; leave the plugin off |
| Chat Commands uploads/lookups | Your kill counts, personal bests, etc. for the `!` chat commands, plus lookups of other players' stats | `api.runelite.net` | **Only if** you enable the Chat Commands plugin (**off by default** in this build) | Opt-in; leave the plugin off |

**Non-opt-in fetches (no account data; a normal HTTP request that reveals your IP to the host):**

| Data | What it is | Host | When | Notes |
|---|---|---|---|---|
| Game-launcher config | `jav_config` — the gamepack + game-server parameters | Jagex (`oldschool.config.runescape.com`; backup `static.runelite.net`) | At boot | Required to start the engine |
| Live game cache fetch | OSRS art/data the engine streams to render the world (incl. its CRC/version validation, over the game connection) | Jagex (JS5 cache) | First login / on update | Required to play |
| Runtime config | A small feature-flag/config blob RuneLite serves to all clients | RuneLite CDN (`static.runelite.net/config.json`) | At boot | Download only; no payload sent |
| World list | The OSRS world list for the world hopper / map | RuneLite API (`api.runelite.net`) | When the world switcher loads | Download only; no payload sent |
| Item prices | The GE price table plugins use to value items | RuneLite API (`api.runelite.net/…/prices.js`) | At boot and on login | Download only; no payload sent |
| Hub plugin downloads | Third-party plugin code you choose to install | RuneLite plugin repo (`repo.runelite.net`) | When you install a hub plugin | You choose what to install |

That is the complete list of outbound connections. **No telemetry, analytics, or crash reports
are among them, and nothing carries your account data except the first table — where every
account-data row is opt-in.**

## What is **not** collected or sent

- **No telemetry** — Java/OS version, device memory, "logged-in" flags: none of it is sent
  (`--disable-telemetry` is passed at boot).
- **No session heartbeat** — stock RuneLite pings `api.runelite.net` every 10 minutes with a random
  session id + a logged-in flag; this build points that endpoint at a local sink, so it never leaves
  the device.
- **No Grand Exchange offer uploads** — stock RuneLite crowdsources every GE offer event tagged with a
  stable machine fingerprint (hashed MACs/OS/account); this build drops that upload entirely while the
  local GE panel and trade history keep working.
- **No crash reporting** — JVM crash logs are **not** uploaded anywhere; they remain on-device.
- **No analytics, ads, tracking, or fingerprinting.** No third-party SDKs of that kind are present.
- **No gameplay data to anyone but Jagex, in the default configuration** — chat, inventory, location,
  XP, menu contents are part of the normal game connection to Jagex and are sent **nowhere else**
  unless you opt in by enabling Loot Tracker / Chat Commands or signing into a RuneLite account
  (first table above).
- **No account email or password to the maintainer** — there is no maintainer backend to send them to.

## What is stored on the device

All paths are in the app's **private** storage unless marked *external* (adb-reachable) or
*debug-only* (never present in a release build).

| Data | Where (Android: app `filesDir`; iOS: app sandbox) | Notes |
|---|---|---|
| Jagex session token | `tokens.json` (app-private) | Written on login, deleted on logout. **No release build bundles one.** |
| RuneLite account session | `.runelite/` config dir | Only after you opt into account sync |
| OSRS live cache (~200 MB+) | `.runelite/jagexcache/oldschool/LIVE/` | Streamed from Jagex; persists between sessions |
| Client + plugin settings | `.runelite/settings.properties`, profile files | Synced to RuneLite **only** if you sign in |
| Renderer choice, hotkeys | app preferences (`renderer`, `hotkeys`) | On-device only |
| Diagnostics (GPU-fallback cookie, thermal marker) | `gpu-fail.txt`, `thermal-throttle.marker` (app-private) | **On-device only — never transmitted** |
| Embedded JVM + client jars (~500 MB) | `jvm/` | Unpacked from the app on first run |

### Debug-only (stripped from release builds)

These exist solely to make development convenient and are **removed from any release artifact**:

- **Legacy username/password** (`legacy_login.json`) — plaintext dev autologin; dropped entirely in
  release (`LegacyCreds` returns nothing in release).
- **Bundled / external token copies** — a debug build may bundle a throwaway `tokens.json` and mirror
  it to *external* storage for `adb push`; a **release build ships none and never writes to external
  storage**.
- **Frame captures / diagnostic markers** (`rl-capture/`, `netprobe.mode`, etc.) — debug-gated; inert
  in release.

## Third parties

- **Jagex Ltd.** — receives your login handshake and game traffic. Required to play. Governed by
  Jagex's own terms and privacy policy.
- **The RuneLite project** — receives your config/plugin data **only if** you opt into RuneLite-account
  sync, and your loot / chat-command data **only if** you enable those two plugins (off by default in
  this build). Separately, its CDN/API serves all clients a runtime-config blob, the world list, and the
  item-price table at boot, and hub-plugin downloads you choose to install — these are downloads that
  send no account data (they reveal your IP, as any HTTP request does). Governed by RuneLite's terms.
- **No one else.**

## Notes & risk

- This client is **not on Jagex's approved-client list**; using it can get an account **banned**.
  Use a **throwaway** account. (See `SECURITY.md` and `README.md`.)
- Hub plugins run **inside the embedded JVM with full privileges**, by design — auditing third-party
  plugins you install is your responsibility.
- This is a single-maintainer, best-effort personal project. If a future build changes any data flow,
  this document will be updated alongside it.
