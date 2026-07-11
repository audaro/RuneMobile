# A4 — plugin control plane (seam first)

Wires RuneLite's plugin control plane (`MobileUiBridge`) into the Android host — the phase that delivers
"**all plugins** toggle/config natively" (see `../../PORT-PHASING.md` Phase A4, `../../BLUEPRINT.md` §C).
Built incrementally; this directory tracks the **seam** (the host↔engine path), with the UI on top next.

## A3.5 — bridge request/response thread (done)
ART threads are NOT attached to the embedded HotSpot VM, and the ART UI thread must never block on a HotSpot
call (ANR). So plugin-plane calls run on a dedicated `rl-bridge` background thread (`JvmLauncher.onBridge {}`)
that daemon-attaches to HotSpot in the native layer; strings cross the VM boundary as UTF-8
(`jvm_bootstrap.cpp` `nativeListPlugins/nativeMobileUiSeq/nativePollMobileUiEvents/nativeSetPluginEnabled`).

## A4 seam — host reaches MobileUiBridge (GREEN)
A-1b proved `listPlugins()` returns a live ~32 KB list **in-VM**. The seam proves the **host** can pull that
same list **across** the boundary on the rl-bridge thread — the path A4's UI uses. Census mode runs a
read-only host self-test (`MainActivity.runA4SeamSelfTest`): poll `listPlugins()` until the engine has booted
and `-Drunelite.mobileui` has wired it, then log the received length + the event seq.

```
( cd ../../.. && cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug )
adb install -r ../../app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop dev.audaro.runemobile ; adb logcat -c
adb shell am start -n dev.audaro.runemobile/.MainActivity --ez census true
# after LOGGED_IN:
./check-a4seam.sh
```

### GREEN baseline (emulator `rl_arm64`, 2026-06-08)
```
ANDROID_A4_SEAM_GREEN   listPluginsLen=~32300 mobileUiSeq=<n>
ANDROID_A4_TOGGLE_GREEN plugin=<className> true->false->true seq=<s0>-><s1> ack={"ok":true,"queued":"edt"}
ANDROID_A4_CONFIG_GREEN group=<group> configLen=<n> writeId=<w>
```
Read list + toggle (write, restored) + config-schema read, all across ART↔HotSpot on the rl-bridge thread —
the complete A4 data plane. (List length ≈ the in-VM A-1b 32230 confirms the full list crossed intact; the
toggle confirms a write round-trip via the flag + the event seq; the config line confirms the typed schema the
config UI renders.)

## Next (this phase, not yet built)
- **UI:** a Jetpack Compose plugin list (switches, calling `setPluginEnabled`) + a typed config screen (bool→Switch, int/double→field,
  enum→picker, color→picker, string→text), parsing the bridge JSON. Plugin Hub (`-Drunelite.hub`, pin
  `runelite.pluginhub.version` to a published rev — the `1.12.29-SNAPSHOT` has none → 404).
- `flushConfig()` on `onPause`/screen-close (config doesn't persist otherwise).
