#!/usr/bin/python3
"""sim-heat-check.py - run the heat steps in the iOS Simulator, on each renderer, and read them back from Share logs.

The simulator's phone is always cool, so the driver's "heat" command stands in for the phone's readings. For each
renderer this boots to the login screen and checks that:
  - a cool phone is left alone, and the game runs faster than every limit below (or the limits would prove nothing)
  - Low Power Mode holds it to 30 fps, and turning it off lifts that at once
  - a critical phone holds it to 20 fps, and the report shows the state, the limit and the frame rate
  - the report's minute lines say where the frames went
On the first renderer it also checks the limit comes off a step after a minute of calm. On 117HD it moves the
resolution setting as a player would, before and during a throttle, and checks the player's value is the one that
comes back, then kills the app mid-throttle with that throttle saved and checks the next launch puts the player's
value on disk before it drops the marker. It does that again with a player's move during a steady throttle: the limit
has to hold, and the move has to reach the marker before the kill. Then, last, it boots as a new install does, with no
saved renderer and 117HD's seed sentinel taken out of the profile. The app has to pick base GPU, a 30 fps cap and base
GPU's shorter draw distance, with both surviving a kill as soon as it says they're saved. A cap taken off and a distance
moved have to stay as the player left them, and 117HD has to start on its light settings and boot for real on them. The
profile and the app's defaults are put back afterwards.

What the simulator can't say: how hot any of this runs, or anything in the world. There the GPU modes draw with
Apple's software renderer at about 3 fps, under every limit, and 117HD sits in its shader compile, so this stays at
the login screen, and 117HD's path through the limit needs a phone. Prints SIM_HEAT_GREEN or _RED. Run with
/usr/bin/python3 (the harness needs PIL).

  /usr/bin/python3 ios/dev-tools/diagnostics/sim-heat-check.py               # build, install, all three renderers
  /usr/bin/python3 ios/dev-tools/diagnostics/sim-heat-check.py --no-build gpu
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "ios/dev-tools/sim-screens"))
import screendriver as sd  # noqa: E402
from screendriver import hs  # noqa: E402

LIMIT_WAIT = 30  # seconds for a new limit to show in the report: a heat tick is 120 display ticks
# What a new install's renderers start on, as the saved profile spells it. Base GPU's comes from the app's first-run
# flag and 117HD's from its seed, whose sentinel is what says it has been run before.
NEW_GPU = {"gpu.drawDistance": "30"}
NEW_HD = {"hd.tiledLighting": "OFF", "hd.dynamicLights": "FEW", "hd.shadowMode": "FAST",
          "hd.enableShadowTransparency": "false", "hd.antiAliasingMode": "MSAA_2", "hd.sceneResolutionScale": "85",
          "hd.drawDistance": "30"}
HD_SEEDED = "hd.iosGfxSeeded"
MOVED_GPU = {"gpu.drawDistance": "40"}  # a player's own value, which no launch after the first may touch
# The app's defaults a first run reads or writes, and how to write each back.
APP_DEFAULTS = {"rendererPref": "-string", "autoGpuFailed": "-bool", "newInstallDefaults": "-bool"}
SETTLE = 9       # then long enough that the report's frame rate was measured wholly under it
SLACK = 1.15     # the report's frame rate is measured over one tick, so it may read a little high


class Run:
    def __init__(self, drv):
        self.drv = drv
        self.problems = []

    def section(self):
        ok, why, _seq = self.drv.open("report")
        if not ok:
            raise sd.DriverError(f"report command failed: {why}")
        report = (self.drv.docs / "screen-report.txt").read_text(encoding="utf-8")
        m = re.search(r"== Heat ==\n(.*?)\n== ", report, re.S)
        if not m:
            raise sd.DriverError("the report has no Heat section")
        return m.group(1)

    def heat(self, thermal, low_power):
        ok, why, _seq = self.drv.open(f"heat {thermal} {low_power}")
        if not ok:
            raise sd.DriverError(f"heat command failed: {why}")

    def wait_for(self, phrase, seconds=LIMIT_WAIT):
        """The Heat section once it has `phrase`, or None."""
        end = time.time() + seconds
        while time.time() < end:
            text = self.section()
            if phrase in text:
                return text
            time.sleep(2)
        return None

    def now(self, text):
        return text.splitlines()[0] if text else ""

    def fps(self, text):
        m = re.search(r"\| (\d+) fps \|", self.now(text))
        return int(m.group(1)) if m else None

    def expect_limit(self, label, phrase, cap):
        """The report reaches `phrase`, and the frame rate is under `cap` once it has been there a while."""
        if not self.wait_for(phrase):
            self.problems.append(f"{label}: no '{phrase}' after {LIMIT_WAIT} s: {self.now(self.section())}")
            return
        time.sleep(SETTLE)
        text = self.section()
        fps = self.fps(text)
        print(f"  {label}: {self.now(text)}", flush=True)
        if fps is None or (cap and fps > cap * SLACK):
            self.problems.append(f"{label}: wanted at most {cap} fps: {self.now(text)}")


def launch(drv, udid, args, wait_for):
    drv.cmd_file.unlink(missing_ok=True)
    # A crash cookie from a launch killed before its first frame would quietly boot this one on CPU.
    (drv.docs.parent / "Library/Application Support/hd-boot-armed").unlink(missing_ok=True)
    launched = time.time()
    if subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, hs.IOS_BUNDLE_ID] + args,
                      stdout=subprocess.DEVNULL).returncode != 0:
        raise sd.DriverError("simctl launch failed")
    ok, details = hs._sim_wait(udid, wait_for, 300, since=launched)
    if not ok:
        raise sd.DriverError(f"the app didn't reach {wait_for}: {details.get('reason')}")
    time.sleep(sd.BOOT_SETTLE)
    return launched


def check_renderer(drv, udid, renderer, lift):
    print(f"{renderer}:", flush=True)
    launch(drv, udid, ["-rendererPref", renderer, "-RMAutoPlay", "YES", "-RMScreenDriver", "YES", "-RMSkipLogin", "YES"],
           "LOGIN_SCREEN")
    run = Run(drv)

    # Up to two ticks to get a reading, then one with the game already running.
    text = run.wait_for("thermal nominal", LIMIT_WAIT)
    time.sleep(SETTLE)
    text = run.section()
    fps = run.fps(text)
    print(f"  cool: {run.now(text)}", flush=True)
    if "no limit" not in run.now(text):
        run.problems.append(f"cool: {run.now(text)}")
    if fps is None or fps <= 30:
        run.problems.append(f"cool: the game runs at {fps} fps, so the limits below can't show: {run.now(text)}")

    check_timing(run, renderer, False)  # check_first_run starts 117HD for real: this launch waits for the world
    if renderer == "117hd":
        check_players_scale(run)

    run.heat(0, 1)
    run.expect_limit("Low Power Mode", "limited to 30 fps", 30)
    if "Low Power Mode on" not in run.section():
        run.problems.append("Low Power Mode isn't in the report")
    run.heat(0, 0)
    if not run.wait_for("no limit"):
        run.problems.append("turning Low Power Mode off didn't lift its limit")

    run.heat(3, 0)
    run.expect_limit("critical", "limited to 20 fps", 20)
    if "thermal critical" not in run.section():
        run.problems.append("the report doesn't say critical")

    if lift:
        run.heat(0, 0)
        if run.wait_for("limited to 30 fps", 90):
            print("  a minute of calm: 20 -> 30", flush=True)
        else:
            run.problems.append(f"no step down after a minute of calm: {run.now(run.section())}")
    return run.problems


def check_players_scale(run):
    """The player's own value survives the governor, whichever side of a throttle they set it, and the limit reaches
    a value raised from under it. 100 is left behind."""
    for step, want in (("hd-scale 80", None), ("heat 2 0", "117HD scale 65 of 80"), ("hd-scale 90", None),
                       ("heat 0 0", "117HD scale 90 of 90"), ("hd-scale 40", None), ("heat 2 0", "117HD scale 40 of 40"),
                       ("hd-scale 100", "117HD scale 65 of 100"), ("heat 0 0", "117HD scale 100 of 100")):
        ok, why, _seq = run.drv.open(step)
        if not ok:
            raise sd.DriverError(f"{step} failed: {why}")
        if want:
            text = run.wait_for(want, 90)
            print(f"  {step}: {run.now(text) if text else 'no ' + want}", flush=True)
            if not text:
                run.problems.append(f"the player's scale: wanted '{want}': {run.now(run.section())}")
        else:
            time.sleep(2)
    if not run.wait_for("no limit", 90):  # the last step down, so the next check starts from a cool phone
        run.problems.append(f"the limit didn't clear: {run.now(run.section())}")


def saved_scale(drv):
    """117HD's scale in the saved profile, or None if the profile doesn't set it."""
    values = []
    for f in (drv.docs / ".runelite/profiles2").glob("*.properties"):
        values += re.findall(r"^hd\.sceneResolutionScale=(\d+)", f.read_text(errors="replace"), re.M)
    return int(values[-1]) if values else None


def marker(drv, udid):
    """The throttle marker in the app's own defaults, through cfprefsd because the app's plist lags it."""
    prefs = drv.docs.parent / "Library/Preferences" / hs.IOS_BUNDLE_ID
    r = subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "read", str(prefs), "thermalBaselineScale"],
                       capture_output=True, text=True)
    return int(r.stdout) if r.returncode == 0 else None


def check_killed_mid_throttle(drv, udid):
    """Critical, saved, killed. The launch after has to get the player's 100 back on disk before the marker goes."""
    print("killed mid-throttle:", flush=True)
    problems = []
    ok, why, _seq = drv.open("config-flush")
    if not ok:
        raise sd.DriverError(f"config-flush failed: {why}")
    time.sleep(3)
    before = saved_scale(drv)
    if before is None or before >= 100:
        return [f"the throttle wasn't saved, so this proves nothing: saved scale {before}"]
    launch(drv, udid, ["-rendererPref", "117hd", "-RMAutoPlay", "YES", "-RMScreenDriver", "YES", "-RMSkipLogin", "YES"],
           "LOGIN_SCREEN")
    end = time.time() + 30
    while time.time() < end and marker(drv, udid) is not None:
        time.sleep(1)
    left, saved = marker(drv, udid), saved_scale(drv)
    print(f"  saved {before} before; marker {left}, saved {saved} after", flush=True)
    if left is not None:
        problems.append(f"the marker is still there: {left}")
    if saved != 100:
        problems.append(f"the marker went with {saved} on disk, wanted 100")
    return problems


def check_moved_during_steady_throttle(drv, udid):
    """Critical and holding, so the governor has nothing to write. A player's 80 still has to survive a kill."""
    print("a player moves the setting during a steady throttle, and is killed:", flush=True)
    run = Run(drv)
    run.heat(3, 0)
    if not run.wait_for("117HD scale 50 of 100", 90):
        return [f"no throttle to move under: {run.now(run.section())}"]
    ok, why, _seq = drv.open("hd-scale 80")
    if not ok:
        raise sd.DriverError(f"hd-scale failed: {why}")
    problems = []
    if not run.wait_for("117HD scale 50 of 80", LIMIT_WAIT):
        problems.append(f"the limit didn't hold over the player's 80: {run.now(run.section())}")
    end = time.time() + LIMIT_WAIT
    while time.time() < end and marker(drv, udid) != 80:
        time.sleep(1)
    held = marker(drv, udid)
    if held != 80:
        problems.append(f"marker {held} after the player's move, wanted 80")
    ok, why, _seq = drv.open("config-flush")
    if not ok:
        raise sd.DriverError(f"config-flush failed: {why}")
    time.sleep(3)
    before = saved_scale(drv)
    launch(drv, udid, ["-rendererPref", "117hd", "-RMAutoPlay", "YES", "-RMScreenDriver", "YES", "-RMSkipLogin", "YES"],
           "LOGIN_SCREEN")
    end = time.time() + 30
    while time.time() < end and marker(drv, udid) is not None:
        time.sleep(1)
    left, saved = marker(drv, udid), saved_scale(drv)
    print(f"  killed with {before} saved, marker {held}; marker {left}, saved {saved} after", flush=True)
    if left is not None:
        problems.append(f"the marker is still there: {left}")
    if saved != 80:
        problems.append(f"the player's 80 didn't survive the kill: saved scale {saved}")
    drv.open("hd-scale 100")
    time.sleep(2)
    drv.open("config-flush")
    return problems


def profile_files(drv):
    return list((drv.docs / ".runelite/profiles2").glob("*.properties"))


def saved_settings(drv, keys):
    """The keys' values in the saved profile, as far as it sets them."""
    found = {}
    for f in profile_files(drv):
        for key, value in re.findall(r"^([\w.]+)=(.*)$", f.read_text(errors="replace"), re.M):
            if key in keys:
                found[key] = value
    return found


def forget_settings(drv, keys):
    """Takes the keys out of the saved profile, to leave one that has never run a renderer."""
    pattern = re.compile(r"^(?:" + "|".join(re.escape(k) for k in keys) + r")=.*\n", re.M)
    for f in profile_files(drv):
        f.write_text(pattern.sub("", f.read_text(errors="replace")))


def app_default(udid, prefs, key):
    """The app's default as `defaults` prints it, None if it isn't set."""
    read = subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "read", str(prefs), key],
                          capture_output=True, text=True)
    return read.stdout.strip() if read.returncode == 0 else None


def set_app_default(udid, prefs, key, value):
    spawn = ["xcrun", "simctl", "spawn", udid, "defaults"]
    if value is None:
        subprocess.run(spawn + ["delete", str(prefs), key], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.run(spawn + ["write", str(prefs), key, APP_DEFAULTS[key], value], check=True)


def wait_for_line(drv, text, since, seconds):
    """True once this launch's shell log has the text."""
    end = time.time() + seconds
    while time.time() < end:
        if drv.shell_log.stat().st_birthtime >= since - 1 and \
                text in drv.shell_log.read_text(encoding="utf-8", errors="replace"):
            return True
        time.sleep(0.5)
    return False


def settle_settings(drv, want):
    """Saves until the profile holds what's wanted: a seed queues on the client thread, and a save doesn't wait for it."""
    end = time.time() + LIMIT_WAIT
    while True:
        ok, why, _seq = drv.open("config-flush")
        if not ok:
            raise sd.DriverError(f"config-flush failed: {why}")
        time.sleep(3)
        found = saved_settings(drv, want)
        if found == want or time.time() > end:
            return found


def frame_cap(drv):
    """What Share logs says the frame-rate cap is."""
    ok, why, _seq = drv.open("report")
    if not ok:
        raise sd.DriverError(f"report command failed: {why}")
    report = (drv.docs / "screen-report.txt").read_text(encoding="utf-8")
    m = re.search(r"^Frame-rate cap: (.+)$", report, re.M)
    return m.group(1) if m else None


def wait_for_frame_cap(drv, want, seconds):
    end = time.time() + seconds
    while True:
        cap = frame_cap(drv)
        if cap == want or time.time() > end:
            return cap
        time.sleep(2)


def check_timing(run, renderer, waits_for_gpu):
    """The minute lines have to say where the frames went. Only 117HD's frame fences show a GPU wait here: on base GPU's
    login frame the simulator's glFinish returns at once, as the app's own [perf] line says (gpuFinish=0.00 ms)."""
    end = time.time() + 75  # the first line closes a minute after the first reading
    while time.time() < end:
        m = re.search(r"frame ([\d.]+)  cpu ([\d.]+|-)  gpu ([\d.]+)  worst ([\d.]+) \(cpu ([\d.]+|-) gpu ([\d.]+)\)"
                      r"  cores ([\d.]+)", run.section())
        if m:
            print(f"  timing: {m.group(0)}", flush=True)
            frame, cpu, gpu, cores = float(m.group(1)), m.group(2), float(m.group(3)), float(m.group(7))
            if cpu == "-" or float(cpu) <= 0 or float(cpu) > frame * 2:
                run.problems.append(f"{renderer}: the game thread's CPU reads {cpu} of a {frame} ms frame")
            if cores <= 0:
                run.problems.append(f"{renderer}: the app's CPU reads {cores} cores")
            if waits_for_gpu and gpu <= 0:
                run.problems.append(f"{renderer}: no time waiting for the GPU")
            return
        time.sleep(3)
    run.problems.append(f"{renderer}: no timing in the report after a minute: {run.section()[-300:]}")


def check_first_run(drv, udid):
    """A new install: the renderer it picks, the cap it gets, and what each renderer starts on. The profile is put back."""
    print("new install:", flush=True)
    args = ["-RMAutoPlay", "YES", "-RMScreenDriver", "YES", "-RMSkipLogin", "YES"]
    subprocess.run(["xcrun", "simctl", "terminate", udid, hs.IOS_BUNDLE_ID], stderr=subprocess.DEVNULL)
    saved = {f: f.read_bytes() for f in profile_files(drv)}
    forget_settings(drv, [HD_SEEDED] + list(NEW_GPU) + list(NEW_HD))
    # By path: the app's defaults are in its own container, and the bundle id would name the simulator's global ones.
    prefs = drv.docs.parent / "Library/Preferences" / hs.IOS_BUNDLE_ID
    before = {key: app_default(udid, prefs, key) for key in APP_DEFAULTS}
    for key in ("rendererPref", "autoGpuFailed"):
        set_app_default(udid, prefs, key, None)
    problems = []
    try:
        launched = launch(drv, udid, args, "LOGIN_SCREEN")
        picked = re.findall(r"first-run caps probe -> default renderer (\S+)",
                            drv.shell_log.read_text(encoding="utf-8", errors="replace"))
        print(f"  picked {picked[-1] if picked else 'nothing'}", flush=True)
        if not picked or picked[-1] != "gpu" or drv.shell_log.stat().st_mtime < launched:
            problems.append(f"a new install picked {picked[-1] if picked else 'nothing'}, wanted gpu")

        # The app says they're saved, and is killed with nothing else to save them: they have to be there already.
        saved_line = wait_for_line(drv, "[shell] new install:", launched, 90)
        subprocess.run(["xcrun", "simctl", "terminate", udid, hs.IOS_BUNDLE_ID], stderr=subprocess.DEVNULL)
        gpu = saved_settings(drv, NEW_GPU)
        launch(drv, udid, args, "LOGIN_SCREEN")
        cap = wait_for_frame_cap(drv, "30 fps", LIMIT_WAIT)
        print(f"  killed once saved: {saved_line}; base GPU {gpu}, frame-rate cap {cap}", flush=True)
        if not saved_line:
            problems.append("the app never said a new install's settings were saved")
        if cap != "30 fps":
            problems.append(f"a new install's cap is {cap}, wanted 30 fps")
        if gpu != NEW_GPU:
            problems.append(f"base GPU started on {gpu}, wanted {NEW_GPU}")

        # Both are the player's from here, so only a first run may set them.
        ok, why, _seq = drv.open("fps-cap 0")
        if not ok:
            raise sd.DriverError(f"fps-cap failed: {why}")
        cap = wait_for_frame_cap(drv, "none", LIMIT_WAIT)
        settle_settings(drv, NEW_GPU)  # saves the cap coming off
        subprocess.run(["xcrun", "simctl", "terminate", udid, hs.IOS_BUNDLE_ID], stderr=subprocess.DEVNULL)
        forget_settings(drv, list(MOVED_GPU))
        for f in profile_files(drv):
            if "default-" in f.name:
                f.write_text(f.read_text(errors="replace") + "".join(f"{k}={v}\n" for k, v in MOVED_GPU.items()))
        launch(drv, udid, args, "LOGIN_SCREEN")
        time.sleep(SETTLE)
        after = frame_cap(drv)
        moved = settle_settings(drv, MOVED_GPU)
        print(f"  cap taken off: {cap}, and the next launch: {after}, with {moved}", flush=True)
        if cap != "none" or after != "none":
            problems.append(f"the cap came back: {cap} after taking it off, {after} on the next launch")
        if moved != MOVED_GPU:
            problems.append(f"the next launch moved the player's draw distance: {moved}, wanted {MOVED_GPU}")

        # Booted for real on these settings, on the login screen: a seed that didn't compile stops the plugin there.
        since = launch(drv, udid, ["-rendererPref", "117hd", "-RM117HDAtLogin", "YES"] + args, "LOGIN_SCREEN")
        first = wait_for_line(drv, "117HD first GL present", since, 180)
        hd = settle_settings(drv, NEW_HD)
        print(f"  117HD: first present {first}, {hd}", flush=True)
        if not first:
            problems.append("117HD didn't get to a first present on a new install's settings")
        if hd != NEW_HD:
            problems.append(f"117HD started on {hd}, wanted {NEW_HD}")
        run = Run(drv)
        check_timing(run, "117hd", True)
        problems += run.problems
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", udid, hs.IOS_BUNDLE_ID], stderr=subprocess.DEVNULL)
        for f, data in saved.items():
            f.write_bytes(data)
        for key, value in before.items():
            set_app_default(udid, prefs, key, value)
    return problems


def main():
    ap = argparse.ArgumentParser(description="Run the heat steps in the iOS Simulator.")
    ap.add_argument("renderers", nargs="*", default=["cpu", "gpu", "117hd"])
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--jars", action="store_true")
    args = ap.parse_args()

    udid, err = hs._sim_udid({"sim_udid": os.environ.get("SIM_UDID")})
    if not udid:
        print(f"SIM_HEAT_RED no simulator: {err}")
        return 1
    problems = []
    try:
        sd.install(udid, no_build=args.no_build, jars=args.jars)
        drv = sd.Driver(udid)
        for i, renderer in enumerate(args.renderers):
            problems += [f"{renderer}: {p}" for p in check_renderer(drv, udid, renderer, i == 0)]
            if renderer == "117hd":
                problems += check_killed_mid_throttle(drv, udid)
                problems += check_moved_during_steady_throttle(drv, udid)
        problems += check_first_run(drv, udid)
    except sd.DriverError as e:
        print(f"SIM_HEAT_RED {e}")
        return 1
    if problems:
        print("SIM_HEAT_RED")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"SIM_HEAT_GREEN {' '.join(args.renderers)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
