# RuneLite on iPhone — install guide

A native iPhone build of RuneLite. It's not on the App Store, so setup takes ~15 minutes and one quick
computer step. After that you install the app and run it from your phone.

**Read this first:**
- ⚠️ **Use a throwaway OSRS account, never your main.** This isn't a Jagex-approved client, so the account
  carries a ban risk. That's on the account you log in with.
- You'll **enable "JIT" before each launch** (one tap in another app) — the game won't start without it.
- Free Apple ID apps expire after **7 days**; you re-refresh in one tap. No charge, no jailbreak.

---

## What you need

- An iPhone on **iOS 17.4 or newer**, with a **passcode set**.
- A **computer** (Windows / Mac / Linux) **once**, plus a USB cable.
- An **Apple ID** (a throwaway one is fine).
- A **throwaway OSRS account.**
- Two files I'll send you: the app **`RuneLite.ipa`** and a small script **`runelite-jit.js`**.

> Heads up on naming: once installed, the app's icon is labelled **RuneMobile** (not "RuneLite"). That's
> the name to look for on your Home Screen and in StikDebug's app list.

---

## Step 1 — Make a "pairing file" (computer, ~5 min, one time)

This lets your phone enable JIT and refresh apps on its own afterward.

1. Plug your iPhone into the computer with USB.
2. Download **idevice_pair** → https://github.com/jkcoxson/idevice_pair (or Jitterbug). Run it.
3. It saves a small `.mobiledevicepairing` file. AirDrop / email it to your phone.

Full walkthrough: https://docs.sidestore.io/docs/advanced/pairing-file

## Step 2 — Install SideStore (the installer)

SideStore is the app that installs and re-signs other apps using *your own* Apple ID.

1. Get it from **https://sidestore.io** and follow their install steps.
2. In **Settings → Privacy & Security**, turn on **Developer Mode** (it'll prompt a restart).
3. Open SideStore → import the **pairing file** from Step 1 → install the **WireGuard VPN** it asks for.
4. Sign in with your **Apple ID** when prompted.

## Step 3 — Install the game

1. In SideStore, tap **＋** (top corner) → choose the **`RuneLite.ipa`** I sent you.
2. SideStore signs it with your Apple ID and installs it. The icon (labelled **RuneMobile**) lands on
   your Home Screen.

*(No UDID, no info from your phone needed — SideStore handles signing locally.)*

## Step 4 — Install StikDebug (the JIT enabler)

StikDebug isn't on the App Store — you install it through SideStore, same as the game.

1. In SideStore, add the **StikDebug** source (link on its page: https://github.com/StephenDev0/StikDebug),
   or download the **StikDebug `.ipa`** from there and open it in SideStore like you did in Step 3.
2. Also install **LocalDevVPN** (StikDebug links to it) — the loopback VPN it uses to switch JIT on.
3. Open StikDebug once → enter your passcode → **import the same pairing file** from Step 1.

## Step 5 — Load the JIT script and assign it (one time)

This app needs a custom script so JIT works — the normal StikDebug "just connect" won't boot it.

1. Get **`runelite-jit.js`** (the file I sent) onto the phone: AirDrop it, or save it into **Files**.
2. Import it into StikDebug — use its in-app **"add/import script"** button, or drop the file into
   **Files → On My iPhone → StikDebug → scripts/**.
3. In StikDebug, open the app list, select **RuneMobile**, and **assign `runelite-jit.js`** as its script.
   StikDebug remembers this, so you only do it once.

---

## Each time you play

1. Turn on the **LocalDevVPN** toggle.
2. Open **StikDebug**, pick **RuneMobile** (with `runelite-jit.js` assigned), and let it **attach**.
   You'll see it switch JIT on (StikDebug's log shows `[rl-jit]` lines).
3. The app boots and drops you into the game. Play.

> If you open RuneMobile *without* attaching StikDebug first, it just waits / won't start. That's
> expected — do the two steps above and it'll continue.

## Logging in

1. In the app, tap **Log in with Jagex**.
2. Sign in to your **throwaway account** in the window that appears, pick your character. Done — it stays
   logged in between launches.

---

## Keeping it working

- **Every 7 days:** open SideStore and tap **Refresh** on RuneMobile (it can also auto-refresh over the VPN).
  If it ever won't open, it's usually just expired — refresh and reopen.
- **Every launch:** re-enable JIT via StikDebug (the "Each time you play" step).

## If something's off

- *App won't launch / just hangs* → JIT wasn't enabled. Do the StikDebug step (LocalDevVPN on first), then reopen.
- *Attaches but crashes, or no `[rl-jit]` lines in StikDebug's log* → the script isn't assigned. Redo
  Step 5 (import `runelite-jit.js` and assign it to RuneMobile).
- *Only one VPN runs at a time* → use SideStore's VPN to install/refresh, LocalDevVPN to enable JIT.
  Toggle whichever you need for the task at hand.
- *"Unable to install" in SideStore* → make sure SideStore's VPN is on and you're signed into your Apple ID.
- *Can't enable Developer Mode* → you must have a passcode set first, then look under
  Settings → Privacy & Security.
