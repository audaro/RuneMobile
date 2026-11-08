"""screendriver.py - the script side of the app's -RMScreenDriver (ViewController.m, simScreenTick).

Shared by sim-screens.py (goldens) and plugin-sweep.py. The app reads "<seq> <screen>" from Documents/screen-cmd on
its display tick, opens the screen through the same method its button calls, and answers in hello-shell.log:
"[screen] info <seq> <json>" (what the screen shows) and then "[screen] ready <seq> <screen>", or
"[screen] failed <seq> <screen>: <why>". Run with /usr/bin/python3 (tools/mcp needs PIL + numpy).
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/mcp"))
import harness_server as hs  # noqa: E402  (simulator, capture and diff helpers)

# Logged out on the CPU renderer with the game picture covered, so a screen looks the same from run to run whatever
# the game behind it is doing. Landscape is pinned too: a simulator left in portrait mode (Game settings > Screen)
# draws portrait inside the landscape window, and every shot comes out sideways.
LAUNCH_ARGS = ["-rendererPref", "cpu", "-screen.portrait", "NO", "-screen.auto", "NO", "-RMAutoPlay", "YES",
               "-RMSkipLogin", "YES", "-RMBlankGame", "YES", "-RMScreenDriver", "YES"]
# After the login screen first shows, the plugin rail and the account rows are still filling in.
BOOT_SETTLE = 3.0
SCREEN_TIMEOUT = 30
_SCREEN_LINE = re.compile(r"\[screen\] (ready|failed) (\S+) (.+)$")
_INFO_LINE = re.compile(r"\[screen\] info (\S+) (\{.*\})$")


class DriverError(Exception):
    pass


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def device_name(udid):
    rc, o, _e = hs.run(["xcrun", "simctl", "list", "devices", "-j"], timeout=60)
    if rc == 0:
        for devs in json.loads(o)["devices"].values():
            for d in devs:
                if d["udid"] == udid:
                    return d["name"]
    return udid


def install(udid, no_build=False, jars=False):
    """run-sim.sh --no-launch: build (unless no_build) and install the CPU simulator app."""
    flags = ["--no-launch"] + (["--no-build"] if no_build else []) + (["--jars"] if jars else [])
    env = dict(os.environ, SIM_UDID=udid, RENDERER="cpu")
    if subprocess.run(["bash", str(hs.RUN_SIM)] + flags, cwd=REPO, env=env).returncode != 0:
        raise DriverError("run-sim.sh failed to build or install the app")


class Driver:
    """A driven launch of the installed app: launch(), then open() screens in turn."""

    def __init__(self, udid):
        self.udid = udid
        docs, why = hs._sim_docs(udid)
        if not docs:
            raise DriverError(why)
        self.docs = docs
        self.cmd_file = docs / "screen-cmd"
        self.shell_log = docs / "hello-shell.log"
        self.jvm_log = docs / "jvm-stdio.log"
        self.seq = 0

    def launch(self, model):
        """Launch with LAUNCH_ARGS, wait for the login screen, and check the window is landscape."""
        self.cmd_file.unlink(missing_ok=True)
        launched = time.time()
        rc = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", self.udid,
                             hs.IOS_BUNDLE_ID] + LAUNCH_ARGS, stdout=subprocess.DEVNULL).returncode
        if rc != 0:
            raise DriverError(f"simctl launch failed ({rc})")
        ok, details = hs._sim_wait(self.udid, "LOGIN_SCREEN", 300, since=launched)
        if not ok:
            raise DriverError(f"the app didn't reach the login screen: {details.get('reason')}")
        time.sleep(BOOT_SETTLE)
        # simctl captures in the device's portrait frame and sim_capture turns it by the window rotation
        # Simulator.app records per device. LAUNCH_ARGS keep the app in landscape, so a window still in portrait
        # gives sideways shots.
        try:
            probe, _info = hs.sim_capture(self.udid, mask_island=False)
        except RuntimeError as e:
            raise DriverError(f"screenshot failed: {e.args[0]}")
        if probe.width < probe.height:
            raise DriverError(
                f"the {model} window in Simulator.app is in portrait, so every shot would come out sideways. "
                "Turn it to landscape once (Device > Rotate Left); Simulator remembers it for this device.")

    def _event(self, seq, name):
        """('ready'|'failed', detail) once the app has answered command `seq`, else None."""
        for line in reversed(hs._read_tail(self.shell_log, 300)):
            m = _SCREEN_LINE.search(line)
            if not m or m.group(2) != str(seq):
                continue
            if m.group(1) == "ready":
                return ("ready", "") if m.group(3) == name else ("failed", f"the app answered for {m.group(3)!r}")
            rest = m.group(3)
            return "failed", rest[len(name) + 2:] if rest.startswith(name + ": ") else rest
        return None

    def info(self, seq):
        """The app's "[screen] info" for command `seq` (a dict), or None."""
        for line in reversed(hs._read_tail(self.shell_log, 300)):
            m = _INFO_LINE.search(line)
            if m and m.group(1) == str(seq):
                try:
                    return json.loads(m.group(2))
                except ValueError:
                    return None
        return None

    def open(self, name):
        """Have the app open `name` ('-' closes); (True, '', seq) once it says ready, else (False, why, seq)."""
        self.seq += 1
        seq = self.seq
        tmp = self.cmd_file.with_name(self.cmd_file.name + ".tmp")
        tmp.write_text(f"{seq} {name}\n")
        os.replace(tmp, self.cmd_file)
        start = time.time()
        while time.time() - start < SCREEN_TIMEOUT:
            ev = self._event(seq, name)
            if ev:
                return ev[0] == "ready", ev[1], seq
            if self._exited():
                return False, "the app exited", seq
            time.sleep(0.2)
        return False, f"no answer from the app within {SCREEN_TIMEOUT}s", seq

    def _exited(self):
        """True when the app is missing from the simulator's launchctl list three times, a second apart. A single
        `simctl spawn` that fails or comes back without it, under load, isn't an exit."""
        for attempt in range(3):
            if hs._sim_app_pid(self.udid) is not None:
                return False
            if attempt < 2:
                time.sleep(1.0)
        return True

    def capture(self):
        """An upright RGB PIL image of the simulator screen. Raises DriverError."""
        try:
            im, _info = hs.sim_capture(self.udid, mask_island=False)
        except RuntimeError as e:
            raise DriverError(f"screenshot failed: {e.args[0]}")
        return im
