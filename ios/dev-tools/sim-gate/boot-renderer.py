#!/usr/bin/env python3
"""boot-renderer.py - launch the simulator app on one renderer, logged out, and check that renderer is the one
that started.

  SIM_UDID=<udid> /usr/bin/python3 ios/dev-tools/sim-gate/boot-renderer.py <cpu|gpu|117hd> [--timeout S] [--dwell S]

sim-gate.sh runs it once per renderer against the build it installed. The launch is -RMSkipLogin, so it never logs
into the game. It passes when, within --timeout seconds of the launch:
  - the client reaches LOGIN_SCREEN;
  - the shell logs "renderer pref = <renderer>" (a boot the crash cookie demoted to CPU logs cpu);
  - cpu: the GPU and 117HD plugins are force-disabled; gpu: "GPU first frame"; 117hd: "117HD first GL present"
    (the app's own survival proofs, which clear the crash cookie);
and the app is still running --dwell seconds later, so lines logged just after the login screen (World Hopper's
first ping) are in the logs the gate scans. Shader errors are counted by the gate's log scan, not here.

117hd runs two launches. A player's comes first: 117HD must stay off on the login screen and the picture must keep
moving there, because iOS shows CPU frames until the world has warmed up and 117HD stops them. That launch can't prove
117HD works, having no world to reach, so the second one starts it on the login screen with -RM117HDAtLogin. The
second is last because the app rotates its logs at launch, and that is the launch the gate has to scan.

A crash cookie left by an earlier GPU or 117HD launch that died or was killed before its first frame would demote
this launch to CPU, so it is removed first (and reported). Exits 0 exactly when the renderer started; the last line
is RENDERER_OK <renderer> or RENDERER_FAIL <renderer>.
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from PIL import ImageChops

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/mcp"))
import harness_server as hs  # noqa: E402  (simulator helpers)

LAUNCH_ARGS = ["-RMAutoPlay", "YES", "-RMSkipLogin", "YES"]
HD_AT_LOGIN = ["-RM117HDAtLogin", "YES"]
COOKIE = "Library/Application Support/hd-boot-armed"
FIRST_FRAME = {
    "cpu": "-Drunelite.forceDisablePlugins=gpuplugin,hdplugin",
    "gpu": "[shell] GPU first frame - crash cookie cleared",
    "117hd": "[shell] 117HD first GL present - crash cookie cleared",
}
DEMOTED = "did not survive its last launch"
HD_START = "Starting 117 HD"
HD_START_WAIT = 15  # seconds on the login screen; 117HD starts about 2 s in when it is going to
PICTURE_GAP = 2  # seconds between the two shots of the login screen
# The middle band of the game canvas: the login box and the fires either side, none of the native HUD. The key strip
# appears over the canvas's bottom left during a login, which would read as a moving picture.
CANVAS_BAND = (0.16, 0.30, 0.84, 0.55)


def fail(renderer, why):
    print(f"!! {renderer}: {why}")
    print(f"RENDERER_FAIL {renderer}")
    sys.exit(1)


def fresh_lines(path, since):
    """This launch's lines of a log the app rotates at start, else []."""
    try:
        if path.stat().st_birthtime < since - 1:
            return []
        return path.read_text(errors="replace").splitlines()
    except OSError:
        return []


def canvas_band(udid):
    im, _info = hs.sim_capture(udid, mask_island=False)
    w, h = im.size
    x0, y0, x1, y1 = CANVAS_BAND
    return im.crop((int(w * x0), int(h * y0), int(w * x1), int(h * y1)))


def launch(r, udid, extra=()):
    """Start the app on renderer r. Returns the launch's epoch."""
    since = time.time()
    p = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, hs.IOS_BUNDLE_ID,
                        "-rendererPref", r] + LAUNCH_ARGS + list(extra), capture_output=True, text=True)
    if p.returncode != 0:
        fail(r, f"simctl launch failed ({p.returncode}): {(p.stderr or p.stdout).strip()[-300:]}")
    return since


def check_login_screen_stays_live(udid, docs, timeout):
    """A player's launch on 117HD: it waits for the world, so the login screen goes on moving."""
    r = "117hd"
    since = launch(r, udid)
    ok, d = hs._sim_wait(udid, "LOGIN_SCREEN", timeout, since=since)
    if not ok:
        fail(r, f"no login screen on a player's launch: {d.get('reason')}")
    time.sleep(HD_START_WAIT)
    if hs._sim_app_pid(udid) is None:
        fail(r, "the app exited on the login screen on a player's launch")
    if any(HD_START in ln for ln in fresh_lines(docs / "jvm-stdio.log", since)):
        fail(r, "117HD started on the login screen, which stops the picture there")
    first = canvas_band(udid)
    time.sleep(PICTURE_GAP)
    if ImageChops.difference(first.convert("RGB"), canvas_band(udid).convert("RGB")).getbbox() is None:
        fail(r, f"the login screen's picture did not change in {PICTURE_GAP} s")
    print(f"   {r}: a player's login screen stays live, 117HD still off after {HD_START_WAIT}s")


def main():
    ap = argparse.ArgumentParser(description="Boot the simulator app on one renderer and check it started.")
    ap.add_argument("renderer", choices=sorted(FIRST_FRAME))
    ap.add_argument("--timeout", type=int, default=300, help="seconds from launch to the first frame (default 300)")
    ap.add_argument("--dwell", type=int, default=15, help="seconds to keep it running afterwards (default 15)")
    args = ap.parse_args()
    r = args.renderer
    udid = os.environ.get("SIM_UDID")
    if not udid:
        fail(r, "SIM_UDID is not set")
    docs, why = hs._sim_docs(udid)
    if not docs:
        fail(r, why)
    cookie = docs.parent / COOKIE
    if cookie.exists():
        cookie.unlink()
        print("   removed a crash cookie left by an earlier GPU/117HD launch that did not reach its first frame")

    if r == "117hd":
        check_login_screen_stays_live(udid, docs, args.timeout)
    since = launch(r, udid, HD_AT_LOGIN if r == "117hd" else ())

    ok, d = hs._sim_wait(udid, "LOGIN_SCREEN", args.timeout, since=since)
    if not ok:
        tail = "\n".join("      " + ln for ln in (d.get("tail") or [])[-8:])
        fail(r, f"no login screen: {d.get('reason')}" + (f"\n{tail}" if tail else ""))
    login_after = d.get("reachedAfterLaunchSec")

    shell_log = docs / "hello-shell.log"
    want_pref = f"[shell] renderer pref = {r}"
    while True:
        lines = fresh_lines(shell_log, since)
        demoted = next((ln for ln in lines if DEMOTED in ln), None)
        if demoted:
            fail(r, f"the app demoted the renderer: {demoted.strip()}")
        prefs = [ln.strip() for ln in lines if ln.startswith("[shell] renderer pref = ")]
        if prefs and prefs[-1] != want_pref:
            fail(r, f"asked for {r}, the shell logged '{prefs[-1]}'")
        frame = next((ln for ln in lines if FIRST_FRAME[r] in ln), None)
        if prefs and frame:
            break
        if time.time() - since > args.timeout:
            missing = [m for m, seen in ((want_pref, prefs), (FIRST_FRAME[r], frame)) if not seen]
            fail(r, f"within {args.timeout}s of the launch the shell never logged: {' / '.join(missing)}")
        if hs._sim_app_pid(udid) is None:
            fail(r, "the app exited before its first frame")
        time.sleep(1)
    m = re.search(r"sinceStartMs=(\d+)", frame)
    proof = "GPU and 117HD plugins disabled" if r == "cpu" else \
        f"first {'GL present' if r == '117hd' else 'GPU frame'} after " + (f"{int(m.group(1)) / 1000:.1f}s" if m else "?")

    for _ in range(args.dwell):
        if hs._sim_app_pid(udid) is None:
            fail(r, f"the app exited within {args.dwell}s of the login screen")
        time.sleep(1)
    print(f"   {r}: login screen after {login_after}s, {proof}, still running {args.dwell}s later")
    print(f"RENDERER_OK {r}")


if __name__ == "__main__":
    main()
