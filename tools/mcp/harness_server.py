#!/usr/bin/env python3
"""
runelite-ios harness MCP server.

A small stdio MCP (Model Context Protocol) server that exposes the project's
dev-tools harnesses as callable tools, plus two net-new capabilities that the
repo did not have before: a PNG pixel-diff (the long-planned maxChannelDelta
golden compare) and an evidence-catalog indexer.

Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout.
Pinned interpreter: /usr/bin/python3 (system Python — ships PIL + numpy, which
image_diff and ios_sim_screenshot import, and which the sim-screens.py that
ios_sim_screens runs under this interpreter needs). All other tools are pure
stdlib + subprocess.

Tools
-----
  headless_render        run the desktop headless capture, return PNG paths + log markers
  image_diff             per-channel pixel diff of two PNGs (+ heatmap) — the missing T12.1
  jvm_bench              run the jvmbench throughput baseline, return parsed ops/s
  glsl_es_validate       run the GLES 3.00 shader-downport validator
  list_evidence          index evidence/*.png catalogs into JSON (name, dir, size, mtime)
  android_screenshot     adb screencap + pull from a connected device/emulator
  android_set_hd_config  live 117HD preset flip (SET_HD_CONFIG broadcast) — the FIX-13 A/B knob
  android_fps            run the fps-measure harness for N seconds, return mean/median/min/max
  run_verdict            run any *-verdict.sh against a log, return GREEN/RED
  ios_pull_logs          devicectl copy of Documents/jvm-stdio.log (+ client.log) off the iPhone
  ios_sim_run            build, install and launch the app in the iOS Simulator, wait for a frame or game state
  ios_sim_wait           wait for the simulator app's current launch to reach a frame or game state
  ios_sim_screenshot     simulator screenshot, upright, Dynamic Island painted out, optionally sized like a phone shot
  ios_sim_census         the iOS bridge census: every JNI lookup the app makes, resolved in the simulator's VM
  ios_sim_screens        golden screenshots of the native screens in the simulator, each compared with its golden

Nothing here is destructive: every tool reads, renders, measures, or flips a
runtime debug knob.

The output parsers are pure functions (parse_*), covered by test_harness_server.py.
"""

import sys
import os
import re
import io
import json
import time
import glob
import base64
import shutil
import subprocess
import tempfile
import traceback
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_NAME = "runelite-ios-harness"
SERVER_VERSION = "0.4.0"
DEFAULT_PROTOCOL = "2024-11-05"

# The JREs each port embeds. Both are gitignored staging output, so either may be missing on a fresh clone;
# jvm_bench falls back to PINNED_JAVA_MAJOR and says so.
EMBEDDED_JRE_RELEASES = ("ios/dev-tools/jre/release", "android/app/src/main/assets/jvm/jre/release")
PINNED_JAVA_MAJOR = 21

# Verdict scripts that take a second log (mobileui: cross-launch persistence). The others ignore $2, so a
# second log passed to them would be dropped without a word; run_verdict refuses that instead.
TWO_LOG_VERDICTS = ("mobileui-verdict.sh",)

IOS_BUNDLE_ID = "dev.audaro.runemobile"
FPS_MEASURE = REPO_ROOT / "android/dev-tools/gpu/fps-measure.sh"
RUN_SIM = REPO_ROOT / "ios/dev-tools/run-sim.sh"
RUN_CENSUS_SIM = REPO_ROOT / "ios/dev-tools/bridge-census/run-census-sim.sh"
RUN_SIM_SCREENS = REPO_ROOT / "ios/dev-tools/sim-screens/sim-screens.py"
SIM_RENDERERS = ("cpu", "gpu", "117hd")
# The Dynamic Island in a raw (portrait) simctl screenshot at 3x: width, height, offset from the top, in pixels,
# centred. simctl draws it into its screenshots over the app; phone screenshots don't have it.
SIM_ISLAND_PX = (376, 110, 42)
# The perf probe's logs in the app's Documents: Debug keeps all VM output in jvm-stdio.log; Release writes none,
# except perf-probe.log (the probe's own lines) when the perfprobe marker arms it (ViewController.m captureStdio).
IOS_PERF_LOGS = ("jvm-stdio.log", "perf-probe.log")
# Debug builds keep .runelite in Documents; Release moves it to Application Support (JVMLauncher.m rlHome).
IOS_CLIENT_LOG_SOURCES = (
    "Documents/.runelite/logs/client.log",
    "Library/Application Support/.runelite/logs/client.log",
)


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #
def log(msg):
    """Diagnostics go to stderr — stdout is the protocol channel."""
    sys.stderr.write(f"[harness-mcp] {msg}\n")
    sys.stderr.flush()


def run(cmd, cwd=None, timeout=120, env=None, stdin=None):
    """Run a command, return (rc, stdout, stderr). Never raises on non-zero."""
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    try:
        p = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            timeout=timeout,
            env=full_env,
            input=stdin,
            capture_output=True,
            text=True,
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") if isinstance(e.stdout, str) else ""
        err = (e.stderr or "") if isinstance(e.stderr, str) else ""
        return 124, out, err + f"\n[timeout after {timeout}s]"
    except FileNotFoundError as e:
        return 127, "", str(e)


def find_jdk():
    # openjdk@11 is also installed here, but only for deliberate cross-version runs (pass jdk= explicitly).
    for cand in (
        "/opt/homebrew/opt/openjdk@21",
        os.environ.get("JAVA_HOME", ""),
    ):
        if cand and Path(cand, "bin", "java").exists():
            return cand
    return None


def java_major(version):
    """'21.0.8' -> 21, '1.8.0_402' -> 8, '26' -> 26. None if unparseable."""
    m = re.match(r"(\d+)(?:\.(\d+))?", version or "")
    if not m:
        return None
    major = int(m.group(1))
    if major == 1 and m.group(2):
        return int(m.group(2))
    return major


def jdk_version(jdk):
    rc, o, e = run([f"{jdk}/bin/java", "-version"], timeout=30)
    m = re.search(r'version "([^"]+)"', e + "\n" + o)
    return m.group(1) if m else None


def embedded_java_versions():
    """JAVA_VERSION of each staged port JRE that exists, keyed by repo-relative release path."""
    found = {}
    for rel in EMBEDDED_JRE_RELEASES:
        p = REPO_ROOT / rel
        if p.exists():
            m = re.search(r'^JAVA_VERSION="([^"]+)"', p.read_text(errors="replace"), re.M)
            if m:
                found[rel] = m.group(1)
    return found


def find_adb():
    for cand in (
        shutil.which("adb"),
        os.path.join(os.environ.get("ANDROID_HOME", ""), "platform-tools", "adb"),
        os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"),
    ):
        if cand and Path(cand).exists():
            return cand
    return None


def text_block(obj):
    if isinstance(obj, str):
        return {"type": "text", "text": obj}
    return {"type": "text", "text": json.dumps(obj, indent=2)}


def err_result(msg):
    return {"content": [text_block(msg)], "isError": True}


def ok_result(blocks):
    if isinstance(blocks, dict) or isinstance(blocks, str):
        blocks = [text_block(blocks)]
    return {"content": blocks, "isError": False}


# --------------------------------------------------------------------------- #
# output parsers (pure, so test_harness_server.py can feed them real log shapes)
# --------------------------------------------------------------------------- #
def frame_draw_number(path):
    """HeadlessCapture names frames frame-<STATE>-<n>-draw<NNNNN>.png; the draw counter is the timeline."""
    m = re.search(r"-draw(\d+)\.png$", str(path))
    return int(m.group(1)) if m else -1


def frame_state(path):
    m = re.match(r"frame-(.+)-\d+-draw\d+\.png$", Path(path).name)
    return m.group(1) if m else None


def order_frames(paths):
    """Chronological by draw counter. A name sort is wrong: LOGIN_SCREEN sorts after LOGGED_IN."""
    return sorted(paths, key=lambda p: (frame_draw_number(p), str(p)))


def pick_last_frame(paths):
    """The newest LOGGED_IN frame if the run reached the game, else the newest frame of any state."""
    ordered = order_frames(paths)
    logged_in = [p for p in ordered if frame_state(p) == "LOGGED_IN"]
    if logged_in:
        return logged_in[-1]
    return ordered[-1] if ordered else None


def parse_capture_markers(text):
    """Markers from a HeadlessCapture log. The game state is never logged as 'gameState='; it rides on
         [headless-capture] draw#200 nullGraphics=0 capturedFrames=3 state=LOGIN_SCREEN
         [headless-capture] gameState LOGGING_IN -> LOADING (draw#253 loginIndex=10 launcher=true)
    plus the loginIndex transition line, which also carries state=. The last one in log order is current."""
    markers = {}
    m = re.findall(r"\[headless-capture\] draw#\d+ nullGraphics=(\d+)", text)
    if m:
        markers["nullGraphics"] = m[-1]
    m = re.findall(r"\[headless-capture\] .*?(?:\bstate=|gameState \w+ -> )(\w+)", text)
    if m:
        markers["gameState"] = m[-1]
    transitions = re.findall(r"\[headless-capture\] gameState (\w+) -> (\w+)", text)
    if transitions:
        markers["gameStateProgression"] = [transitions[0][0]] + [b for _a, b in transitions]
    lines = text.splitlines()
    markers["exceptionLines"] = sum(1 for ln in lines if "Exception" in ln)
    # logback's level column; a login 401 is an ERROR line with no Exception in it.
    markers["errorLines"] = sum(1 for ln in lines if " ERROR " in ln)
    return markers


_VERDICT_WORDS = ("GREEN", "RED", "INCONCLUSIVE")


def parse_verdict(text):
    """(verdict, token) from a *-verdict.sh's output; verdict is GREEN, RED, INCONCLUSIVE, NO_VERDICT,
    LOG_MISSING or UNKNOWN.

    A script that reaches a verdict ends on 'VERDICT: <TOKEN>', where TOKEN is the bare word (mobileui,
    menupeek) or wraps it (EDGE2EDGE_GREEN_AS_EXPECTED, HUD_ISO_RED). Earlier lines print PASS/FAIL per
    predicate and echo the JVM's own '[hud-iso] VERDICT ...' line, so only the last anchored line counts.
    The early exits (2 = probe never emitted, 3 = inconclusive) print no VERDICT: line."""
    tokens = re.findall(r"^\s*VERDICT:\s*([A-Z0-9_]+)", text, re.M)
    if tokens:
        tok = tokens[-1]
        parts = tok.split("_")
        for word in _VERDICT_WORDS:
            if word in parts:
                return word, tok
        return "UNKNOWN", tok
    m = re.search(r"\b[A-Z0-9_]+_NO_VERDICT\b", text)
    if m:
        return "NO_VERDICT", m.group(0)
    if "INSTRUMENT_INVALID" in text:
        return "INCONCLUSIVE", "INSTRUMENT_INVALID"
    if re.search(r"^>>> INCONCLUSIVE\b", text, re.M):
        return "INCONCLUSIVE", "INCONCLUSIVE"
    if "!! log not found" in text:
        return "LOG_MISSING", None
    return "UNKNOWN", None


def parse_glsl_es(text):
    """(rows, summary) from glsl_es_repro.py. Each mode prints a header, then its error lines:
         === uiScalingMode=MITCHELL (ord 2) -> FAIL ===
            [frag] ERROR: 0:207: '=' :  cannot convert from ...
    and the run ends on 'ALL MODES PASS (vert+frag)' or 'SOME MODES FAIL' (summary PASS / FAIL / None)."""
    rows = []
    for ln in text.splitlines():
        m = re.match(r"=== uiScalingMode=(\w+) \(ord (\d+)\) -> (PASS|FAIL) ===$", ln.strip())
        if m:
            rows.append({"mode": m.group(1), "ord": int(m.group(2)), "status": m.group(3), "errors": []})
            continue
        m = re.match(r"\s+\[(vert|frag)\] (.+)", ln)
        if m and rows:
            rows[-1]["errors"].append({"stage": m.group(1), "line": m.group(2).strip()})
    summary = None
    if "ALL MODES PASS" in text:
        summary = "PASS"
    elif "SOME MODES FAIL" in text:
        summary = "FAIL"
    return rows, summary


def parse_bench_results(text):
    """Bench.java prints 'RESULT floatbits.A ops=268435456 ns=1429923791 opsPerSec=187727106 chk=-6971'
    once per timed run (A and B per component). Names carry a dot, so a word-only pattern finds nothing."""
    results = {}
    for name, ops, ns, ops_s in re.findall(
        r"^RESULT ([\w.]+) ops=(\d+) ns=(\d+) opsPerSec=([\d.eE+]+) chk=-?\d+", text, re.M
    ):
        results[name] = {"ops": int(ops), "ns": int(ns), "opsPerSec": float(ops_s)}
    return results


def _num(v):
    for cast in (int, float):
        try:
            return cast(v)
        except ValueError:
            pass
    return v


def parse_fps_measure(text):
    """Summary of android/dev-tools/gpu/fps-measure.sh. It prints one line per probe family that has data:
         LABEL  fps    n=4    mean=49.8  median=49.0  min=46  max=55
         LABEL  frame  windows=4   frames=199   min=17.00  avg=20.09  p95~=22.50  max=140.00  (ms)
         LABEL  gpu    windows=3   frames=149   min=11.00  avg=14.51  max=120.00  (ms GPU)  disjoint=94  hitch=1  empty=1  (excluded: 1 untagged, 1 other-state)
         LABEL  thermal samples=6    hottest=42.5..47.5C  status=1->2 (max 2)
         LABEL  govern changes=1  scale=85  minScale=85  baseline=100
         LABEL  pacing windows=8   frames=472    p50=17.78  p95=19.95  p99=35.48  p999=120.00  max=120.00  jit50=1.00 ...
         LABEL  gc     gcN=3  gcMs=41  heapMaxMB=212  pauses=3  pauseMs=40.50  pauseMax=30.00  safepoints=4 ...
         LABEL  present windows=3   presents=170    perSec=56.7  gapMax=48.00  swapAvg=1.60  swapMax=9.00  (ms)
         LABEL  session n=2950  p50=17.78  ...  pauses=0  gcN=12  gcMs=95  up=60s  (ms, since first frame)
         LABEL  mem    samples=14   tFirst=0.0  tLast=95.5  availMinMB=1601.9  ...  thermalWorst=fair   (iOS memwatch)
         LABEL  coldstart  firstFrame=8123  gpuFirstPresent=15011  (ms since process start)
    a 'fps:   no LOGGED_IN ...' line instead when a family saw only other states (kept under 'missing'), the
    '>> thermal[start]: hottest=84.0C status=1' samples, and '!! ...' warnings. frame p95 is reported as 'p95'
    but is the script's p95~: the mean of the per-second p95s, not a percentile of the whole capture. pacing
    is the real one: percentiles of the summed [framebins] buckets over the capture's LOGGED_IN seconds."""
    out = {"fps": {}, "frameMs": {}, "gpuMs": {}, "thermalRows": {}, "governor": {}, "thermal": {},
           "pacingMs": {}, "gc": {}, "present": {}, "session": {}, "mem": {}, "coldstartMs": {},
           "warnings": [], "missing": []}
    keys = {"fps": "fps", "frame": "frameMs", "gpu": "gpuMs", "thermal": "thermalRows", "govern": "governor",
            "pacing": "pacingMs", "gc": "gc", "present": "present", "session": "session", "mem": "mem",
            "coldstart": "coldstartMs"}
    for ln in text.splitlines():
        m = re.match(r"^\S+\s+(fps|frame|gpu|thermal|govern|pacing|gc|present|session|mem|coldstart)\s+(.*)$", ln)
        if m:
            kind, rest = m.groups()
            d = out[keys[kind]]
            for k, v in re.findall(r"([\w~]+)=([^\s()]+)", rest):
                d[k.rstrip("~")] = _num(v)
            ex = re.search(r"excluded: (\d+) untagged, (\d+) other-state", rest)
            if ex:
                d["excludedUntagged"], d["excludedOtherState"] = int(ex.group(1)), int(ex.group(2))
            if kind == "thermal":
                hot = re.match(r"(.+)\.\.(.+)C$", str(d.pop("hottest", "")))
                if hot:
                    d["hottestMinC"], d["hottestMaxC"] = _num(hot.group(1)), _num(hot.group(2))
                st = str(d.pop("status", "")).split("->")
                if len(st) == 2:
                    d["statusStart"], d["statusEnd"] = _num(st[0]), _num(st[1])
                mx = re.search(r"\(max (\S+)\)", rest)
                if mx:
                    d["statusMax"] = _num(mx.group(1))
            if kind == "session" and isinstance(d.get("up"), str) and d["up"].endswith("s"):
                d["upSeconds"] = _num(d.pop("up")[:-1])
            continue
        m = re.match(r"^(fps|frame|gpu|pacing|present):\s+(no .*)$", ln)
        if m:
            out["missing"].append(ln.strip())
            continue
        m = re.search(r"thermal\[(\w+)\]: hottest=([\w./]+?)C status=([\w/]+)", ln)
        if m:
            out["thermal"][m.group(1)] = {"hottestC": _num(m.group(2)), "status": _num(m.group(3))}
            continue
        if ln.startswith("!! "):
            out["warnings"].append(ln[3:].strip())
    return out


# The simulator app's jvm-stdio.log: the boot poll (every 250 ms for the first 240 s) and HeadlessCapture's periodic
# draw lines carry the draw count and game state, the gameState lines each transition. FATAL lines (no JRE, no VM)
# go through the shell's log sink, so they land in hello-shell.log: callers pass both logs' text.
_SIM_DRAWS = re.compile(r"\[boot\] poll \d+ms\s+draws=(\d+) nullGraphics=(\d+) frames=\d+ state=(\w+)")
_SIM_CAPTURE = re.compile(r"\[headless-capture\] draw#(\d+) nullGraphics=(\d+) capturedFrames=\d+ state=(\w+)")
_SIM_TRANSITION = re.compile(r"\[headless-capture\] gameState \w+ -> (\w+)")
_SIM_FATAL = re.compile(r"\bFATAL\b|A fatal error has been detected|An error report file with more information is saved")


def parse_sim_progress(text):
    """Draw count, latest game state, every state reached and fatal lines from the simulator app's logs."""
    out = {"draws": 0, "nullGraphics": None, "state": None, "states": [], "fatal": []}
    for ln in text.splitlines():
        m = _SIM_DRAWS.search(ln) or _SIM_CAPTURE.search(ln)
        if m:
            out["draws"] = max(out["draws"], int(m.group(1)))
            out["nullGraphics"] = int(m.group(2))
            state = m.group(3)
        else:
            m = _SIM_TRANSITION.search(ln)
            if not m:
                if _SIM_FATAL.search(ln) and len(out["fatal"]) < 5:
                    out["fatal"].append(ln.strip()[-300:])
                continue
            state = m.group(1)
        if state != "null":
            out["state"] = state
            if state not in out["states"]:
                out["states"].append(state)
    return out


def sim_reached(progress, until):
    """until is 'frame' (anything drawn) or a game state the launch has reached at some point."""
    if until == "frame":
        return progress["draws"] > 0
    return until in progress["states"]


def parse_simctl_launch_pid(text, bundle_id):
    """`simctl launch` prints '<bundle id>: <pid>'."""
    m = re.search(re.escape(bundle_id) + r":\s*(\d+)\s*$", text, re.M)
    return int(m.group(1)) if m else None


def parse_launchctl_app_pid(text, bundle_id):
    """The app's pid from `launchctl list` inside the simulator; None when it isn't listed or its pid is '-'."""
    for ln in text.splitlines():
        parts = ln.split()
        if len(parts) >= 3 and parts[2].startswith(f"UIKitApplication:{bundle_id}["):
            return int(parts[0]) if parts[0].isdigit() else None
    return None


def parse_census_output(text):
    """The counts, md5 and misses bridge-census-verdict.sh prints (run_verdict-style VERDICT parsing is separate)."""
    out = {"checked": None, "missing": None, "listed": None, "md5": None, "missingLookups": [], "problems": []}
    m = re.search(r"^checked=(\d+) missing=(\d+) \(list (\d+)\)", text, re.M)
    if m:
        out["checked"], out["missing"], out["listed"] = (int(g) for g in m.groups())
    m = re.search(r"^census_md5=(\w+)", text, re.M)
    if m:
        out["md5"] = m.group(1)
    for ln in text.splitlines():
        ln = ln.strip()
        if ln.startswith("missing: "):
            out["missingLookups"].append(ln[len("missing: "):])
        elif ln.startswith("!! "):
            out["problems"].append(ln[3:])
    return out


def sim_island_rect(width, height):
    """(x0, y0, x1, y1), inclusive, of the Dynamic Island in a raw portrait screenshot."""
    w, h, top = SIM_ISLAND_PX
    x0 = (width - w) // 2
    return x0, top, x0 + w - 1, top + h - 1


def mask_sim_island(arr, pad=3, sample=10, max_spread=6):
    """Paint the Dynamic Island out of a raw portrait screenshot (HxWx3 uint8 array), row by row, with the median
    of what the app draws just beside it on that row: under the island the app's background runs along the island's
    long axis (the native rail, the letterbox). Returns (array, info); the array is untouched when the island isn't
    where it should be, or when the pixels beside it vary along a row (an icon there: nothing safe to fill with)."""
    import numpy as np

    H, W = arr.shape[:2]
    if W >= H:
        return arr, {"masked": False, "reason": "not a portrait screenshot"}
    x0, y0, x1, y1 = sim_island_rect(W, H)
    xa, ya, xb, yb = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    if xa - sample < 0 or ya < 0 or xb + sample >= W:
        return arr, {"masked": False, "reason": "screenshot too small for the island"}
    inner = arr[y0 + 6 : y1 - 5, x0 + 6 : x1 - 5].max(axis=2)
    dark = float((inner <= 4).mean())
    if dark < 0.9:
        return arr, {"masked": False, "reason": f"no island at the expected place ({dark:.0%} of it dark)"}
    out = arr.copy()
    for y in range(ya, yb + 1):
        side = np.concatenate([arr[y, xa - sample : xa], arr[y, xb + 1 : xb + 1 + sample]]).astype(np.int16)
        if int((side.max(axis=0) - side.min(axis=0)).max()) > max_spread:
            return arr, {"masked": False, "reason": f"the pixels beside the island vary along row {y}"}
        out[y, xa : xb + 1] = np.median(side, axis=0).astype(arr.dtype)
    return out, {"masked": True, "rect": [int(xa), int(ya), int(xb - xa + 1), int(yb - ya + 1)]}


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


# --------------------------------------------------------------------------- #
# tools
# --------------------------------------------------------------------------- #
def tool_headless_render(a):
    """Run the desktop headless capture and surface the PNGs it produced."""
    mode = a.get("mode", "login_screen")
    run_seconds = int(a.get("run_seconds", 45))
    interval = int(a.get("capture_interval", 50))

    if mode == "in_game":
        script = REPO_ROOT / "ios/dev-tools/headless/run-headless-login.sh"
        out_dir = REPO_ROOT / "ios/dev-tools/headless/out-login"
        jvm_log = out_dir / "run-native-login.log"
        tokens = REPO_ROOT / "ios/dev-tools/tokens.json"
        if not tokens.exists():
            return err_result(
                "in_game mode needs ios/dev-tools/tokens.json (mint via "
                "ios/dev-tools/fetch-shield-tokens.sh). Use mode=login_screen for no-auth capture."
            )
    else:
        script = REPO_ROOT / "ios/dev-tools/headless/run-headless.sh"
        out_dir = REPO_ROOT / "ios/dev-tools/headless/out"
        jvm_log = out_dir / "run-native.log"

    if not script.exists():
        return err_result(f"missing script: {script}")

    env = {"RUN_SECONDS": str(run_seconds), "CAPTURE_INTERVAL": str(interval)}
    # boot + (optional) login takes a while; give the script room over its own RUN_SECONDS.
    timeout = max(180, run_seconds + 150)
    started = time.time()
    rc, out, err = run(["bash", str(script)], cwd=REPO_ROOT, timeout=timeout, env=env)

    # A script that exits before launching Java (missing tokens/jq) skips its rm of old frames and leaves the
    # previous run's log behind, so only files this run wrote count.
    on_disk = glob.glob(str(out_dir / "frame-*.png"))
    frames = order_frames([f for f in on_disk if os.stat(f).st_mtime >= started])
    combined = out + "\n" + err
    # The script prints only a grep tail of the JVM log, so read the log itself.
    log_fresh = jvm_log.exists() and jvm_log.stat().st_mtime >= started
    markers = parse_capture_markers(jvm_log.read_text(errors="replace") if log_fresh else "")
    markers["frameCount"] = len(frames)
    if len(on_disk) > len(frames):
        markers["staleFramesIgnored"] = len(on_disk) - len(frames)
    by_state = {}
    for f in frames:
        st = frame_state(f) or "?"
        by_state[st] = by_state.get(st, 0) + 1
    markers["framesByState"] = by_state

    return ok_result(
        {
            "ok": rc == 0,
            "mode": mode,
            "exitCode": rc,
            "outputDir": str(out_dir),
            "jvmLog": str(jvm_log) if log_fresh else None,
            "frames": frames[-8:],
            "lastFrame": pick_last_frame(frames),
            "markers": markers,
            "logTail": "\n".join(combined.strip().splitlines()[-25:]),
            "hint": "frames are in draw order; lastFrame is the newest LOGGED_IN frame when there is one. "
            "Open it with the Read tool, or pass two frames to image_diff. jvmLog null = Java never ran.",
        }
    )


def image_delta(ia, ib, threshold=0):
    """Per-channel delta of two same-size RGB PIL images -> (summary, heatmap array). The heatmap's red channel is
    the worst channel's delta x4 (so small deltas show) and its blue marks pixels over threshold."""
    import numpy as np

    na = np.asarray(ia, dtype=np.int16)
    nb = np.asarray(ib, dtype=np.int16)
    diff = np.abs(na - nb)
    per_pixel = diff.max(axis=2)  # worst channel per pixel
    max_delta = int(diff.max())
    h, w = per_pixel.shape
    heat = np.zeros((h, w, 3), dtype=np.uint8)
    heat[..., 0] = np.clip(per_pixel.astype(np.int32) * 4, 0, 255).astype(np.uint8)
    heat[..., 2] = (per_pixel > threshold).astype(np.uint8) * 40
    summary = {
        "ok": max_delta <= threshold,
        "width": w,
        "height": h,
        "maxChannelDelta": max_delta,
        "meanChannelDelta": round(float(diff.mean()), 4),
        "rmse": round(float(np.sqrt((diff.astype(np.float64) ** 2).mean())), 4),
        "pctPixelsDiffering": round(float((per_pixel > threshold).mean() * 100.0), 4),
        "threshold": threshold,
        "identical": max_delta == 0,
    }
    return summary, heat


def tool_image_diff(a):
    """Per-channel pixel diff of two PNGs. The long-planned T12.1 golden compare."""
    try:
        from PIL import Image
        import numpy as np
    except Exception as e:  # pragma: no cover
        return err_result(
            f"image_diff needs PIL + numpy (run the server with /usr/bin/python3). import error: {e}"
        )

    pa, pb = a.get("image_a"), a.get("image_b")
    if not pa or not pb:
        return err_result("image_diff requires image_a and image_b paths.")
    pa, pb = Path(pa), Path(pb)
    if not pa.exists() or not pb.exists():
        return err_result(f"missing: {pa if not pa.exists() else pb}")

    threshold = int(a.get("threshold", 0))
    ia = Image.open(pa).convert("RGB")
    ib = Image.open(pb).convert("RGB")

    crop = a.get("crop")
    if crop and len(crop) == 4:
        x, y, w, h = crop
        box = (x, y, x + w, y + h)
        ia, ib = ia.crop(box), ib.crop(box)

    if ia.size != ib.size:
        return err_result(
            {
                "ok": False,
                "reason": "size mismatch",
                "image_a": [ia.size[0], ia.size[1]],
                "image_b": [ib.size[0], ib.size[1]],
                "hint": "Pass crop=[x,y,w,h] to compare a common region, or render at matching dims.",
            }
        )

    summary, heat = image_delta(ia, ib, threshold)
    out_path = a.get("out") or str(Path(pa).with_suffix("").as_posix() + ".diff.png")
    Image.fromarray(heat).save(out_path)
    summary["diffImage"] = out_path

    blocks = [text_block(summary)]
    # inline the heatmap so it is visible without a second round-trip.
    if a.get("inline", True):
        buf = io.BytesIO()
        Image.fromarray(heat).save(buf, format="PNG")
        blocks.append(
            {
                "type": "image",
                "data": base64.b64encode(buf.getvalue()).decode("ascii"),
                "mimeType": "image/png",
            }
        )
    return ok_result(blocks)


def tool_jvm_bench(a):
    """Compile + run the jvmbench throughput proxy on desktop OpenJDK."""
    explicit = a.get("jdk")
    jdk = explicit or find_jdk()
    if not jdk:
        return err_result("no JDK found (looked at openjdk@21, JAVA_HOME).")
    if not Path(jdk, "bin", "java").exists():
        return err_result(f"not a JDK home (no bin/java): {jdk}")
    version = jdk_version(jdk)
    major = java_major(version)
    if major is None:
        return err_result(f"could not read the version of {jdk}/bin/java (got {version!r}).")
    embedded = embedded_java_versions()
    expected = sorted({java_major(v) for v in embedded.values()} - {None}) or [PINNED_JAVA_MAJOR]
    runtime_match = major in expected
    # A number from the wrong VM reads exactly like a real one, so the default path refuses it; an explicit
    # jdk= is a deliberate cross-version comparison and runs, flagged.
    if not runtime_match and not explicit:
        return err_result(
            {
                "ok": False,
                "reason": f"resolved JDK {version} (major {major}) is not the embedded runtime (major {expected})",
                "jdk": jdk,
                "embeddedRuntime": embedded or {"pinned": PINNED_JAVA_MAJOR},
                "hint": "install openjdk@21, or pass jdk=<home> to benchmark another VM on purpose.",
            }
        )
    bench_dir = REPO_ROOT / "ios/dev-tools/jvmbench"
    src = bench_dir / "Bench.java"
    if not src.exists():
        return err_result(f"missing {src}")
    out = bench_dir / "out"
    out.mkdir(exist_ok=True)

    rc, o, e = run(
        [f"{jdk}/bin/javac", "--release", "8", "-d", str(out), str(src)],
        cwd=bench_dir,
        timeout=120,
    )
    if rc != 0:
        return err_result({"stage": "compile", "exitCode": rc, "stderr": e[-2000:]})

    rc, o, e = run([f"{jdk}/bin/java", "-cp", str(out), "Bench"], cwd=bench_dir, timeout=180)
    results = parse_bench_results(o)
    result_lines = len(re.findall(r"^RESULT ", o, re.M))
    summary = {
        # every RESULT line must parse: a partial table would read as a complete one.
        "ok": rc == 0 and bool(results) and len(results) == result_lines,
        "jdk": jdk,
        "jdkVersion": version,
        "embeddedRuntime": embedded or {"pinned": PINNED_JAVA_MAJOR},
        "runtimeMatch": runtime_match,
        "exitCode": rc,
        "results": results,
        "resultLines": result_lines,
        "raw": o.strip().splitlines()[-10:],
    }
    if not runtime_match:
        summary["warning"] = f"JDK major {major} is not the embedded runtime (major {expected}): cross-version numbers."
    return ok_result(summary)


def tool_glsl_es_validate(a):
    """Run the GLES 3.00 shader-downport validator."""
    script = REPO_ROOT / "ios/dev-tools/headless/glsl_es_repro.py"
    if not script.exists():
        return err_result(f"missing {script}")
    if not shutil.which("glslangValidator"):
        return err_result(
            "glslangValidator not on PATH — install it (brew install glslang) to validate shaders."
        )
    cmd = ["python3", str(script)]
    for cast in a.get("extra_casts") or []:
        if "==" not in cast:
            return err_result(f"extra_casts entries are 'from==to'; got {cast!r}")
        cmd += ["--extra-cast", cast]
    rc, o, e = run(cmd, cwd=REPO_ROOT, timeout=120)
    combined = o + "\n" + e
    rows, summary = parse_glsl_es(combined)
    failures = [r["mode"] for r in rows if r["status"] != "PASS"]
    result = {
        "ok": rc == 0 and bool(rows) and not failures and summary == "PASS",
        "exitCode": rc,
        "summary": summary,
        "results": rows,
        "failures": failures,
        "logTail": combined.strip().splitlines()[-20:],
    }
    if not rows:
        # An exit 0 with nothing parsed means the output format moved, not that every shader passed.
        result["reason"] = "no '=== uiScalingMode=... ===' lines parsed; check glsl_es_repro.py's output format."
    return ok_result(result)


def tool_list_evidence(a):
    """Index evidence PNG catalogs into a sortable JSON manifest."""
    default_dirs = [
        "ios/app/evidence",
        "ios/dev-tools/headless/out",
        "ios/dev-tools/headless/out-login",
        "android/dev-tools/parity",
        "android/dev-tools/qa-2026-06-19/evidence",
        "android/dev-tools/qa-2026-06-19/evidence2",
        "android/dev-tools/firebase/fb-gpu-frames",
    ]
    rel = a.get("dir")
    limit = int(a.get("limit", 60))
    search_dirs = [REPO_ROOT / rel] if rel else [REPO_ROOT / d for d in default_dirs]

    items = []
    for d in search_dirs:
        if not d.exists():
            continue
        for f in glob.glob(str(d / "**/*.png"), recursive=True):
            st = os.stat(f)
            items.append(
                {
                    "path": str(Path(f).relative_to(REPO_ROOT)),
                    "dir": str(Path(f).parent.relative_to(REPO_ROOT)),
                    "name": Path(f).name,
                    "kb": round(st.st_size / 1024, 1),
                    "mtime": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime)),
                    "_t": st.st_mtime,
                }
            )
    items.sort(key=lambda x: x["_t"], reverse=True)
    for it in items:
        it.pop("_t", None)
    return ok_result(
        {"ok": True, "count": len(items), "showing": min(limit, len(items)), "evidence": items[:limit]}
    )


def _adb_base(a):
    adb = find_adb()
    if not adb:
        return None, err_result("adb not found (set ANDROID_HOME or put adb on PATH).")
    cmd = [adb]
    serial = a.get("serial")
    if serial:
        cmd += ["-s", serial]
    return cmd, None


def tool_android_screenshot(a):
    base, e = _adb_base(a)
    if e:
        return e
    out = a.get("out") or str(REPO_ROOT / "android/dev-tools" / f"screen-{int(time.time())}.png")
    # exec-out puts the PNG on stdout. Capture bytes: run() decodes text, which fails on a PNG.
    try:
        p = subprocess.run(base + ["exec-out", "screencap", "-p"], capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return err_result({"error": "screencap timed out after 30 s", "hint": "is the device awake? (adb devices)"})
    if p.returncode != 0 or not p.stdout.startswith(b"\x89PNG"):
        return err_result({"exitCode": p.returncode, "stderr": p.stderr.decode(errors="replace")[-800:],
                           "hint": "is a device/emulator connected? (adb devices)"})
    Path(out).write_bytes(p.stdout)
    return ok_result(
        {"ok": True, "path": out, "bytes": len(p.stdout), "hint": "Read this path to view, or feed it to image_diff."}
    )


def tool_android_set_hd_config(a):
    base, e = _adb_base(a)
    if e:
        return e
    scale = a.get("scene_resolution_scale")
    aniso = a.get("anisotropic_filtering_level")
    if scale is None and aniso is None:
        return err_result("pass scene_resolution_scale and/or anisotropic_filtering_level.")
    cmd = base + ["shell", "am", "broadcast", "-a", "dev.audaro.runemobile.SET_HD_CONFIG"]
    if scale is not None:
        cmd += ["--ei", "sceneResolutionScale", str(int(scale))]
    if aniso is not None:
        cmd += ["--ei", "anisotropicFilteringLevel", str(int(aniso))]
    rc, o, er = run(cmd, timeout=20)
    return ok_result(
        {
            # MainActivity's SET_HD_CONFIG receiver applies any non-reserved extra as a live hd key, so these
            # --ei extras (sceneResolutionScale/anisotropicFilteringLevel) take effect with no rebuild.
            "ok": rc == 0 and ("Broadcast completed" in o or "result=0" in o),
            "exitCode": rc,
            "sent": {"sceneResolutionScale": scale, "anisotropicFilteringLevel": aniso},
            "stdout": o.strip(),
            "stderr": er.strip()[-400:],
        }
    )


def tool_android_fps(a):
    script = FPS_MEASURE
    if not script.exists():
        return err_result(f"missing {script}")
    seconds = int(a.get("seconds", 20))
    label = a.get("label", "mcp")
    csv = a.get("out_csv") or str(REPO_ROOT / "android/dev-tools/gpu" / f"fps-{label}.csv")
    cmd = ["bash", str(script), "-d", str(seconds), "-o", csv]
    if a.get("thermal_every") is not None:
        cmd += ["-t", str(int(a["thermal_every"]))]
    if a.get("serial"):
        cmd += ["-s", a["serial"]]
    cmd += [label]
    rc, o, er = run(cmd, cwd=REPO_ROOT, timeout=seconds + 60)
    combined = o + "\n" + er
    parsed = parse_fps_measure(combined)
    governor_moved = bool(parsed["governor"].get("changes"))
    return ok_result(
        {
            "ok": rc == 0,
            "label": label,
            "exitCode": rc,
            "csv": csv,
            "fps": parsed["fps"],
            "frameMs": parsed["frameMs"],
            "gpuMs": parsed["gpuMs"],
            "thermal": parsed["thermal"],
            "thermalRows": parsed["thermalRows"],
            "governor": parsed["governor"],
            "pacingMs": parsed["pacingMs"],
            "gc": parsed["gc"],
            "present": parsed["present"],
            "session": parsed["session"],
            "coldstartMs": parsed["coldstartMs"],
            # a ThermalGovernor scale change splits the capture into two workloads
            "abClean": not governor_moved,
            "warnings": parsed["warnings"],
            "missing": parsed["missing"],
            "logTail": combined.strip().splitlines()[-15:],
            "hint": "Flip a preset with android_set_hd_config between two android_fps runs; compare pacingMs "
            "p95/p99 and jit95 (real capture percentiles, from [framebins]) and frameMs.avg, not fps, and only "
            "between runs with abClean true. frameMs.p95 is the mean of per-second p95s; session is since the first frame.",
        }
    )


def tool_run_verdict(a):
    script = a.get("script")
    log_path = a.get("log")
    log2_path = a.get("log2")
    if not script:
        return err_result("pass script=<path to a *-verdict.sh>.")
    sp = (REPO_ROOT / script).resolve() if not os.path.isabs(script) else Path(script).resolve()
    # safety: only run vetted verdict scripts inside the repo's dev-tools.
    try:
        sp.relative_to(REPO_ROOT)
    except ValueError:
        return err_result("script must live inside the repo.")
    if not sp.name.endswith("-verdict.sh") or not sp.exists():
        return err_result(f"not a verdict script or missing: {sp}")
    if log2_path and sp.name not in TWO_LOG_VERDICTS:
        return err_result(f"{sp.name} takes one log; log2 is only for {', '.join(TWO_LOG_VERDICTS)}.")
    if log2_path and not log_path:
        return err_result("log2 needs log (the first launch's log).")
    cmd = ["bash", str(sp)]
    for p in (log_path, log2_path):
        if not p:
            continue
        full = (REPO_ROOT / p) if not os.path.isabs(p) else Path(p)
        # mobileui-verdict.sh reads a missing log as empty and says RED; name the real problem instead.
        if not full.is_file():
            return err_result(f"log not found: {full}")
        cmd.append(str(full))
    rc, o, er = run(cmd, cwd=REPO_ROOT, timeout=60)
    combined = o + "\n" + er
    verdict, token = parse_verdict(combined)
    # Every script exits 0 exactly when it says GREEN. Anything else means the parse or the script is off.
    consistent = (verdict == "GREEN") == (rc == 0)
    result = {
        "ok": verdict == "GREEN" and rc == 0,
        "verdict": verdict,
        "verdictToken": token,
        "exitCode": rc,
        "consistent": consistent,
        "logs": len(cmd) - 2,
        "output": combined.strip().splitlines()[-25:],
    }
    if not consistent:
        result["warning"] = f"verdict {verdict} disagrees with exit code {rc}; read output before trusting either."
    return ok_result(result)


def _ios_device(a):
    """(udid, None) for the explicit device, else for the one paired iOS device devicectl lists."""
    if a.get("device"):
        return a["device"], None
    tmp = Path(tempfile.mkdtemp(prefix="harness-devicectl-"))
    try:
        out = tmp / "devices.json"
        rc, _o, e = run(["xcrun", "devicectl", "list", "devices", "--json-output", str(out)], timeout=60)
        if rc != 0 or not out.exists():
            return None, err_result({"stage": "list devices", "exitCode": rc, "stderr": e[-800:]})
        devices = json.loads(out.read_text()).get("result", {}).get("devices", [])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    phones = [
        d
        for d in devices
        if d.get("hardwareProperties", {}).get("platform") == "iOS"
        and d.get("connectionProperties", {}).get("pairingState") == "paired"
    ]
    if len(phones) != 1:
        names = [f"{d.get('deviceProperties', {}).get('name')} {d.get('identifier')}" for d in phones]
        return None, err_result(f"need exactly one paired iOS device, found {len(phones)}: {names}; pass device=<UDID>.")
    return phones[0]["identifier"], None


def _devicectl_copy(udid, bundle_id, source, dest):
    return run(
        [
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", udid,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundle_id,
            "--source", source,
            "--destination", str(dest),
        ],
        timeout=120,
    )


def _perf_summary(log):
    """fps-measure.sh over a pulled iOS log: the same summary android_fps returns, or None if it has no probe lines."""
    if not FPS_MEASURE.exists():
        return None
    rc, o, er = run(["bash", str(FPS_MEASURE), "--from-file", str(log), "ios"], cwd=REPO_ROOT, timeout=60)
    if rc != 0:
        return None
    parsed = parse_fps_measure(o + "\n" + er)
    return {k: v for k, v in parsed.items() if v}


def tool_ios_pull_logs(a):
    """Copy the perf/diagnostic logs (and optionally RuneLite's client.log) out of the app container."""
    if not shutil.which("xcrun"):
        return err_result("xcrun not found (install the Xcode command-line tools).")
    udid, e = _ios_device(a)
    if e:
        return e
    bundle_id = a.get("bundle_id") or IOS_BUNDLE_ID
    # ios/app/evidence/ is gitignored, and list_evidence already indexes it.
    # A fresh dir per pull: a failed pull deletes its dir, which must never hold an earlier pull's files.
    base = REPO_ROOT / "ios/app/evidence/device-pull"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest_dir, n = base / stamp, 1
    while dest_dir.exists():
        dest_dir, n = base / f"{stamp}-{n}", n + 1
    dest_dir.mkdir(parents=True)

    # Neither perf log is required on its own (a build writes one or the other), but one of them must arrive.
    wanted = [(name, (f"Documents/{name}",)) for name in IOS_PERF_LOGS]
    if a.get("client_log"):
        wanted.append(("client.log", IOS_CLIENT_LOG_SOURCES))
    files, attempts = {}, []
    for name, sources in wanted:
        dest = dest_dir / name
        for src in sources:
            rc, o, er = _devicectl_copy(udid, bundle_id, src, dest)
            attempts.append({"source": src, "exitCode": rc, "stderr": er.strip()[-400:]})
            if rc == 0 and dest.is_file():
                text = dest.read_text(errors="replace")
                files[name] = {
                    "path": str(dest.relative_to(REPO_ROOT)),
                    "source": src,
                    "bytes": dest.stat().st_size,
                    "lines": text.count("\n"),
                    "tail": text.strip().splitlines()[-15:],
                }
                if name in IOS_PERF_LOGS:
                    perf = _perf_summary(dest)
                    if perf:
                        files[name]["perf"] = perf
                break
    if not any(name in files for name in IOS_PERF_LOGS):
        shutil.rmtree(dest_dir, ignore_errors=True)
        return err_result(
            {
                "ok": False,
                "reason": f"could not copy {' or '.join(IOS_PERF_LOGS)} from {bundle_id} on {udid}",
                "attempts": attempts,
                "hint": "is the phone unlocked and paired, and was the app launched at least once? A Release build "
                "writes perf-probe.log only with the perfprobe marker (tools/perfprobe.sh ios on) and no "
                "jvm-stdio.log at all. The SideStore release build has a different bundle id (pass bundle_id).",
            }
        )
    return ok_result(
        {
            "ok": True,
            "device": udid,
            "bundleId": bundle_id,
            "dir": str(dest_dir.relative_to(REPO_ROOT)),
            "files": files,
            "attempts": attempts,
            "hint": "files.<log>.perf is fps-measure.sh's summary of that log (pacingMs, gc, present, mem, coldstartMs). "
            "client.log can name the account; it stays in gitignored ios/app/evidence/, delete it when done.",
        }
    )


def _sim_udid(a):
    """(udid, None): the explicit simulator, else the one run-sim.sh would pick (SIM_NAME, iPhone 17 Pro Max)."""
    if a.get("sim_udid"):
        return a["sim_udid"], None
    rc, o, e = run(["bash", str(RUN_SIM), "--print-udid"], cwd=REPO_ROOT, timeout=60)
    lines = o.strip().splitlines()
    if rc != 0 or not lines:
        return None, err_result({"stage": "pick simulator", "exitCode": rc, "stderr": e.strip()[-600:]})
    return lines[-1].strip(), None


def _sim_docs(udid):
    """(Documents dir of the app's data container, None) or (None, why). The path changes on every install."""
    rc, o, e = run(["xcrun", "simctl", "get_app_container", udid, IOS_BUNDLE_ID, "data"], timeout=30)
    if rc != 0 or not o.strip():
        return None, f"the app isn't installed on simulator {udid}: {(e.strip() or o.strip())[-300:]}"
    return Path(o.strip()) / "Documents", None


def _sim_app_pid(udid):
    rc, o, _e = run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"], timeout=30)
    return parse_launchctl_app_pid(o, IOS_BUNDLE_ID) if rc == 0 else None


def _read_tail(path, n):
    try:
        return path.read_text(errors="replace").strip().splitlines()[-n:]
    except OSError:
        return []


def _sim_wait(udid, until, timeout, since=None):
    """Poll the app's logs until `until` ('frame' or a game state) shows up. since (epoch seconds) rejects a log
    from an earlier launch: the app rotates jvm-stdio.log to .prev at start, so the live log's birth time is the
    launch time. Returns (ok, details)."""
    docs, why = _sim_docs(udid)
    if not docs:
        return False, {"reason": why}
    jvm_log, shell_log = docs / "jvm-stdio.log", docs / "hello-shell.log"
    start = time.time()
    seen_running = False
    while True:
        try:
            born = jvm_log.stat().st_birthtime
        except OSError:
            born = None
        fresh = born is not None and (since is None or born >= since - 1)
        progress = None
        if fresh:
            text = jvm_log.read_text(errors="replace") + "\n" + "\n".join(_read_tail(shell_log, 400))
            progress = parse_sim_progress(text)
        details = {
            "until": until,
            "progress": progress,
            "launchedAt": time.strftime("%H:%M:%S", time.localtime(born)) if fresh else None,
            "logs": {"jvm": str(jvm_log), "shell": str(shell_log)},
        }
        if progress and sim_reached(progress, until):
            details["reachedAfterLaunchSec"] = round(time.time() - born, 1)
            details["alreadyReached"] = time.time() - start < 1.5
            return True, details
        if progress and progress["fatal"]:
            return False, dict(details, reason="the app logged a fatal error", tail=_read_tail(shell_log, 25))
        pid = _sim_app_pid(udid)
        seen_running = seen_running or pid is not None
        # Gone with this launch's log in place (or after being seen) means it exited. Before its log appears, a
        # launch gets a moment to show up.
        if pid is None and (seen_running or fresh or time.time() - start > 15):
            return False, dict(details, reason="the app is not running", tail=_read_tail(jvm_log, 25))
        if time.time() - start >= timeout:
            return False, dict(details, reason=f"no {until} within {timeout}s", tail=_read_tail(jvm_log, 25))
        time.sleep(1)


def tool_ios_sim_run(a):
    """run-sim.sh (build, install, launch and press Play), then wait for a frame or a game state."""
    if not shutil.which("xcrun"):
        return err_result("xcrun not found (install Xcode).")
    renderer = a.get("renderer") or ""
    if renderer and renderer not in SIM_RENDERERS:
        return err_result(f"renderer must be one of {', '.join(SIM_RENDERERS)}.")
    udid, e = _sim_udid(a)
    if e:
        return e
    autoplay = a.get("autoplay", True)
    # Without autoplay the app waits on its Play cover and the VM never starts, so there is nothing to wait for.
    until = a.get("until") or ("frame" if autoplay else "none")
    flags = []
    if a.get("jars"):
        flags.append("--jars")
    if not a.get("build", True):
        flags.append("--no-build")
    if a.get("from_phone"):
        flags.append("--from-phone")
    if not autoplay:
        flags.append("--manual")
    env = {"SIM_UDID": udid}
    if renderer:
        env["RENDERER"] = renderer
    since = time.time()
    rc, o, er = run(["bash", str(RUN_SIM)] + flags, cwd=REPO_ROOT, timeout=1800, env=env)
    out = strip_ansi(o + "\n" + er)
    pid = parse_simctl_launch_pid(out, IOS_BUNDLE_ID)
    m = re.search(r"Install \+ launch \(renderer (\w+), autoplay (\w+)\)", out)
    result = {
        "ok": rc == 0 and pid is not None,
        "simUdid": udid,
        "pid": pid,
        "renderer": m.group(1) if m else renderer or None,
        "flags": flags,
        "scriptSec": round(time.time() - since, 1),
    }
    if not result["ok"]:
        lines = [ln for ln in out.splitlines() if ln.strip()]
        return err_result(dict(result, stage="run-sim.sh", exitCode=rc, outputTail=lines[-30:]))
    if until != "none":
        ok, result["wait"] = _sim_wait(udid, until, int(a.get("timeout", 180)), since)
        result["ok"] = ok
    return ok_result(result) if result["ok"] else err_result(result)


def tool_ios_sim_wait(a):
    if not shutil.which("xcrun"):
        return err_result("xcrun not found (install Xcode).")
    udid, e = _sim_udid(a)
    if e:
        return e
    since = a.get("since")
    ok, details = _sim_wait(udid, a.get("until") or "frame", int(a.get("timeout", 120)), float(since) if since else None)
    details = dict(details, ok=ok, simUdid=udid)
    return ok_result(details) if ok else err_result(details)


def _sim_rotation(udid):
    """(angle, orientation) of this device's window from Simulator.app's preferences; angle in PIL's sense
    (counter-clockwise degrees) and None when it isn't recorded."""
    import plistlib

    rc, o, _e = run(["defaults", "export", "com.apple.iphonesimulator", "-"], timeout=15)
    if rc != 0:
        return None, None
    try:
        prefs = plistlib.loads(o.encode()).get("DevicePreferences", {}).get(udid, {})
    except Exception:
        return None, None
    try:
        return float(prefs.get("SimulatorWindowRotationAngle")), prefs.get("SimulatorWindowOrientation")
    except (TypeError, ValueError):
        return None, prefs.get("SimulatorWindowOrientation")


def sim_capture(udid, mask_island=True, rotate="auto"):
    """simctl screenshot -> (upright RGB PIL image, info). Paints the Dynamic Island out first (in the raw
    portrait image, where its place is fixed), then turns the image by Simulator.app's recorded orientation, or by
    `rotate` degrees counter-clockwise. Raises RuntimeError with a result-ready dict when the capture fails."""
    from PIL import Image
    import numpy as np

    tmp = Path(tempfile.mkdtemp(prefix="harness-simshot-"))
    try:
        raw = tmp / "raw.png"
        rc, _o, er = run(["xcrun", "simctl", "io", udid, "screenshot", str(raw)], timeout=60)
        if rc != 0 or not raw.exists():
            raise RuntimeError({"stage": "simctl screenshot", "exitCode": rc, "stderr": er.strip()[-600:],
                                "hint": "is the simulator booted?"})
        im = Image.open(raw).convert("RGB")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    info = {"rawSize": list(im.size), "warnings": []}
    if mask_island:
        arr, info["island"] = mask_sim_island(np.asarray(im))
        im = Image.fromarray(arr)
    if rotate == "auto":
        angle, orientation = _sim_rotation(udid)
        info["orientation"] = orientation
        if angle is None:
            angle = 0
            info["warnings"].append("Simulator.app has no recorded orientation for this device; left as captured.")
    else:
        angle = float(rotate)
    info["rotatedDeg"] = angle
    if angle % 360:
        im = im.rotate(angle, expand=True)
    return im, info


def tool_ios_sim_screenshot(a):
    """simctl screenshot, Dynamic Island painted out, turned upright, optionally resized to a phone screenshot's size."""
    try:
        from PIL import Image
        import numpy as np
    except Exception as e:  # pragma: no cover
        return err_result(f"ios_sim_screenshot needs PIL + numpy (run the server with /usr/bin/python3): {e}")
    udid, e = _sim_udid(a)
    if e:
        return e
    try:
        im, info = sim_capture(udid, a.get("mask_island", True), a.get("rotate", "auto"))
    except RuntimeError as ex:
        return err_result(ex.args[0])
    result = {"ok": True, "simUdid": udid, **info}
    like = a.get("size_like")
    if like:
        like_path = Path(like) if os.path.isabs(like) else REPO_ROOT / like
        if not like_path.is_file():
            return err_result(f"size_like not found: {like_path}")
        ref = Image.open(like_path).size
        ratio = (im.size[0] / im.size[1]) / (ref[0] / ref[1])
        if abs(ratio - 1) > 0.01:
            result["warnings"].append(f"aspect ratios differ by {abs(ratio - 1):.1%}; the resize distorts.")
        im = im.resize(ref, Image.LANCZOS)
    out = a.get("out")
    if out:
        out = Path(out) if os.path.isabs(out) else REPO_ROOT / out
    else:
        # ios/app/evidence/ is gitignored and list_evidence indexes it.
        out = REPO_ROOT / "ios/app/evidence/sim" / f"{time.strftime('%Y%m%d-%H%M%S')}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out)
    result.update(path=str(out), size=list(im.size))
    blocks = [text_block(result)]
    if a.get("inline", True):
        preview = im.copy()
        preview.thumbnail((1000, 1000))
        buf = io.BytesIO()
        preview.save(buf, format="JPEG", quality=80)
        blocks.append({"type": "image", "data": base64.b64encode(buf.getvalue()).decode("ascii"), "mimeType": "image/jpeg"})
    return ok_result(blocks)


def tool_ios_sim_census(a):
    """run-census-sim.sh: build, install, run the census in the simulator, adjudicate."""
    if not shutil.which("xcrun"):
        return err_result("xcrun not found (install Xcode).")
    flags = []
    if a.get("jars"):
        flags.append("--jars")
    if not a.get("build", True):
        flags.append("--no-build")
    env = {"SIM_UDID": a["sim_udid"]} if a.get("sim_udid") else None
    rc, o, er = run(["bash", str(RUN_CENSUS_SIM)] + flags, cwd=REPO_ROOT, timeout=2400, env=env)
    out = strip_ansi(o + "\n" + er)
    verdict, token = parse_verdict(out)
    result = {
        "ok": verdict == "GREEN" and rc == 0,
        "verdict": verdict,
        "verdictToken": token,
        "exitCode": rc,
        # Every verdict script exits 0 exactly when it says GREEN.
        "consistent": (verdict == "GREEN") == (rc == 0),
        **parse_census_output(out),
        "resultFile": "build/bridge-census/result.txt",
        "outputTail": [ln for ln in out.splitlines() if ln.strip()][-20:],
    }
    return ok_result(result) if result["ok"] else err_result(result)


def tool_ios_sim_screens(a):
    """sim-screens.py: open each native screen in the simulator, screenshot it, compare it with its golden."""
    if not shutil.which("xcrun"):
        return err_result("xcrun not found (install Xcode).")
    screens = a.get("screens") or []
    if not isinstance(screens, list) or not all(isinstance(n, str) and n and not n.startswith("-") for n in screens):
        return err_result("screens must be a list of screen names from ios/dev-tools/sim-screens/screens.json")
    flags = list(screens)
    if a.get("update"):
        flags.append("--update")
    if not a.get("build", True):
        flags.append("--no-build")
    if a.get("jars"):
        flags.append("--jars")
    env = {"SIM_UDID": a["sim_udid"]} if a.get("sim_udid") else None
    # The script imports this module for PIL work, so it runs under the same interpreter.
    rc, o, er = run([sys.executable, str(RUN_SIM_SCREENS)] + flags, cwd=REPO_ROOT, timeout=1800, env=env)
    out = strip_ansi(o + "\n" + er)
    verdict, token = parse_verdict(out)
    result = {
        "ok": verdict == "GREEN" and rc == 0,
        "verdict": verdict,
        "verdictToken": token,
        "exitCode": rc,
        "consistent": (verdict == "GREEN") == (rc == 0),
        "outputTail": [ln for ln in out.splitlines() if ln.strip()][-15:],
    }
    m = re.search(r"^summary=(.+)$", out, re.M)
    if m:
        try:
            summary = json.loads(Path(m.group(1).strip()).read_text())
            result.update(results=summary["results"], shots=summary["shots"], goldens=summary["goldens"],
                          model=summary["model"])
        except (OSError, ValueError, KeyError) as e:
            result["summaryError"] = f"{m.group(1).strip()}: {e}"
    return ok_result(result) if result["ok"] else err_result(result)


# --------------------------------------------------------------------------- #
# tool registry (name -> description, inputSchema, handler)
# --------------------------------------------------------------------------- #
TOOLS = {
    "headless_render": (
        "Run the desktop headless RuneLite capture (real engine, no device) and return the PNG "
        "frames in draw order + markers read from the JVM log (nullGraphics, gameState, "
        "gameStateProgression, exceptionLines, framesByState). lastFrame is the newest LOGGED_IN "
        "frame when the run reached the game. mode=login_screen needs no auth; mode=in_game "
        "requires ios/dev-tools/tokens.json (the script's own default run is 120 s). Slow (~1-3 min).",
        {
            "type": "object",
            "properties": {
                "mode": {"type": "string", "enum": ["login_screen", "in_game"], "default": "login_screen"},
                "run_seconds": {"type": "integer", "default": 45},
                "capture_interval": {"type": "integer", "default": 50},
            },
        },
        tool_headless_render,
    ),
    "image_diff": (
        "Per-channel pixel diff of two PNGs: maxChannelDelta, meanChannelDelta, RMSE, "
        "pctPixelsDiffering, plus a red heatmap (inlined). The repo's previously-unimplemented "
        "T12.1 golden compare — use it for desktop-vs-port and regression A/B.",
        {
            "type": "object",
            "properties": {
                "image_a": {"type": "string", "description": "baseline / ground-truth PNG path"},
                "image_b": {"type": "string", "description": "candidate PNG path"},
                "out": {"type": "string", "description": "heatmap output path (optional)"},
                "threshold": {"type": "integer", "default": 0, "description": "per-channel delta tolerance"},
                "crop": {"type": "array", "items": {"type": "integer"}, "description": "[x,y,w,h] common region"},
                "inline": {"type": "boolean", "default": True},
            },
            "required": ["image_a", "image_b"],
        },
        tool_image_diff,
    ),
    "jvm_bench": (
        "Compile (--release 8) and run the jvmbench throughput proxy on desktop OpenJDK 21 (the "
        "ports' runtime); returns parsed ops/s for floatbits, raster, mixed. Refuses a default JDK "
        "whose major differs from the staged JREs'.",
        {
            "type": "object",
            "properties": {
                "jdk": {
                    "type": "string",
                    "description": "JDK home (optional; default openjdk@21, then JAVA_HOME). A JDK passed "
                    "here runs even on a major mismatch, flagged runtimeMatch=false.",
                }
            },
        },
        tool_jvm_bench,
    ),
    "glsl_es_validate": (
        "Run the GLES 3.00 shader-downport validator (glsl_es_repro.py) across uiScalingMode "
        "variants; returns per-mode PASS/FAIL with each mode's glslang errors. Catches the "
        "implicit-cast regressions GLES forbids.",
        {
            "type": "object",
            "properties": {
                "extra_casts": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "extra 'from==to' downport casts to try (--extra-cast), optional",
                }
            },
        },
        tool_glsl_es_validate,
    ),
    "list_evidence": (
        "Index evidence PNG catalogs (ad-hoc evidence/ + headless out*/ dirs) into a JSON "
        "manifest sorted newest-first: path, dir, size, mtime.",
        {
            "type": "object",
            "properties": {
                "dir": {"type": "string", "description": "repo-relative dir (optional; defaults to known catalogs)"},
                "limit": {"type": "integer", "default": 60},
            },
        },
        tool_list_evidence,
    ),
    "android_screenshot": (
        "adb screencap + pull a PNG from a connected Android device/emulator.",
        {
            "type": "object",
            "properties": {
                "serial": {"type": "string", "description": "adb serial (optional)"},
                "out": {"type": "string", "description": "output PNG path (optional)"},
            },
        },
        tool_android_screenshot,
    ),
    "android_set_hd_config": (
        "Live 117HD preset flip via the SET_HD_CONFIG broadcast (no relaunch) — the FIX-13 A/B "
        "knob (sceneResolutionScale, anisotropicFilteringLevel).",
        {
            "type": "object",
            "properties": {
                "scene_resolution_scale": {"type": "integer"},
                "anisotropic_filtering_level": {"type": "integer"},
                "serial": {"type": "string"},
            },
        },
        tool_android_set_hd_config,
    ),
    "android_fps": (
        "Run the fps-measure harness for N seconds against a connected device; returns LOGGED_IN fps, "
        "frame-time, capture pacing percentiles + jitter (pacingMs), GC, present cadence, the session line "
        "(since the first frame), cold start (coldstartMs, when the capture spans a launch), (with "
        "debug.routec.gputime=1) GPU-time stats, per-second thermal, and any "
        "ThermalGovernor scale change (abClean=false). Pair two runs around android_set_hd_config for an A/B.",
        {
            "type": "object",
            "properties": {
                "seconds": {"type": "integer", "default": 20},
                "thermal_every": {
                    "type": "integer",
                    "description": "seconds between thermal samples (default 1; 0 = start/end only)",
                },
                "label": {"type": "string", "default": "mcp"},
                "out_csv": {"type": "string"},
                "serial": {"type": "string"},
            },
        },
        tool_android_fps,
    ),
    "run_verdict": (
        "Run any *-verdict.sh inside the repo against a log file and return its verdict: GREEN, RED, "
        "INCONCLUSIVE, NO_VERDICT, LOG_MISSING or UNKNOWN, read from the script's final VERDICT: line "
        "and cross-checked against its exit code (consistent=false flags a disagreement).",
        {
            "type": "object",
            "properties": {
                "script": {"type": "string", "description": "repo-relative path to a *-verdict.sh"},
                "log": {"type": "string", "description": "log file to adjudicate (optional)"},
                "log2": {
                    "type": "string",
                    "description": "second launch's log; mobileui-verdict.sh only (gates cross-launch persistence)",
                },
            },
            "required": ["script"],
        },
        tool_run_verdict,
    ),
    "ios_pull_logs": (
        "Copy the perf logs off the paired iPhone with devicectl into ios/app/evidence/device-pull/<stamp>/: "
        "Documents/jvm-stdio.log (Debug: all VM output, memwatch, the fault sink) and/or Documents/perf-probe.log "
        "(Release with the perfprobe marker: the probe's lines only), each with fps-measure.sh's summary under "
        "perf (pacing, GC, present cadence, memwatch, cold start). client_log=true adds RuneLite's client.log. "
        "The phone must be unlocked; no JIT attach needed.",
        {
            "type": "object",
            "properties": {
                "device": {"type": "string", "description": "UDID (optional; default the one paired iPhone)"},
                "bundle_id": {"type": "string", "default": IOS_BUNDLE_ID},
                "client_log": {"type": "boolean", "default": False, "description": "also pull client.log (can name the account)"},
            },
        },
        tool_ios_pull_logs,
    ),
    "ios_sim_run": (
        "Build, install and launch RuneMobile in the iOS Simulator (ios/dev-tools/run-sim.sh: full JIT, no phone, "
        "no StikDebug), press Play, then wait until the launch draws a frame (until='frame', ~8 s warm; a fresh "
        "install first downloads the game cache, ~30 s) or reaches a game state (until='LOGIN_SCREEN', ...). "
        "jars=true restages the jars first (after a Java change); build=false reuses the last build; "
        "from_phone=true starts from the paired phone's settings (never its login). Not a perf, GPU-driver, "
        "touch or backgrounding check: those need the phone.",
        {
            "type": "object",
            "properties": {
                "renderer": {"type": "string", "enum": list(SIM_RENDERERS), "description": "default cpu (or the phone's with from_phone)"},
                "build": {"type": "boolean", "default": True},
                "jars": {"type": "boolean", "default": False},
                "from_phone": {"type": "boolean", "default": False},
                "autoplay": {"type": "boolean", "default": True, "description": "false stops at the Play cover (then nothing to wait for)"},
                "until": {"type": "string", "description": "'frame' (default), a game state such as LOGIN_SCREEN, or 'none'"},
                "timeout": {"type": "integer", "default": 180, "description": "seconds to wait after launch"},
                "sim_udid": {"type": "string", "description": "simulator UDID (default: the one run-sim.sh picks)"},
            },
        },
        tool_ios_sim_run,
    ),
    "ios_sim_wait": (
        "Wait for the simulator app's current launch to draw a frame (until='frame') or reach a game state, read "
        "from its jvm-stdio.log. Returns draws, the states reached and the log paths; fails fast if the app exits "
        "or logs a fatal error. since=<epoch seconds> ignores a log from an earlier launch.",
        {
            "type": "object",
            "properties": {
                "until": {"type": "string", "default": "frame"},
                "timeout": {"type": "integer", "default": 120},
                "since": {"type": "number", "description": "epoch seconds; the launch must be no older"},
                "sim_udid": {"type": "string"},
            },
        },
        tool_ios_sim_wait,
    ),
    "ios_sim_screenshot": (
        "Screenshot the iOS Simulator into ios/app/evidence/sim/<stamp>.png, turned upright from Simulator.app's "
        "recorded orientation, with the Dynamic Island painted out (simctl draws it; phone screenshots don't). "
        "size_like=<phone screenshot> resizes to that image's size, so image_diff can compare the two directly. "
        "Inlines a preview.",
        {
            "type": "object",
            "properties": {
                "out": {"type": "string", "description": "output PNG path (optional)"},
                "size_like": {"type": "string", "description": "resize to this image's size (a phone screenshot)"},
                "mask_island": {"type": "boolean", "default": True},
                "rotate": {"description": "'auto' (default) or degrees counter-clockwise (e.g. 90, -90)"},
                "inline": {"type": "boolean", "default": True},
                "sim_udid": {"type": "string"},
            },
        },
        tool_ios_sim_screenshot,
    ),
    "ios_sim_census": (
        "The iOS bridge census (ios/dev-tools/bridge-census/run-census-sim.sh): extracts every class, method and "
        "field the app's native code looks up through JNI, builds and launches the app in the simulator, resolves "
        "each one in the app's own VM once a frame is drawn, and adjudicates: IOS_BRIDGE_CENSUS_GREEN or _RED, "
        "with each missing lookup and the JVM's error for it. ~20 s when the build is current; jars=true restages the jars first.",
        {
            "type": "object",
            "properties": {
                "build": {"type": "boolean", "default": True},
                "jars": {"type": "boolean", "default": False},
                "sim_udid": {"type": "string"},
            },
        },
        tool_ios_sim_census,
    ),
    "ios_sim_screens": (
        "Golden screenshots of the native screens (ios/dev-tools/sim-screens/sim-screens.py): builds and launches "
        "the app in the simulator logged out, CPU renderer, game picture covered; opens each screen in screens.json "
        "(settings, about, plugins, edit-controls, overlays, profiles, infoboxes, panel:<rail tooltip>; hub, which "
        "shows live Plugin Hub data, only when named) through its own button's entry point, screenshots it and "
        "compares it with its golden in "
        "ios/app/evidence/sim-golden/<model>/<facing>/ (LandscapeLeft or LandscapeRight, the way the Simulator "
        "window is turned). Returns SIM_SCREENS_GREEN or _RED with each screen's result, the shot "
        "and, on a FAIL, a diff heatmap. update=true writes the goldens from this run instead. ~40 s for the default "
        "set with an incremental build.",
        {
            "type": "object",
            "properties": {
                "screens": {"type": "array", "items": {"type": "string"}, "description": "default: all of screens.json"},
                "update": {"type": "boolean", "default": False, "description": "write this run's shots as the goldens"},
                "build": {"type": "boolean", "default": True},
                "jars": {"type": "boolean", "default": False},
                "sim_udid": {"type": "string"},
            },
        },
        tool_ios_sim_screens,
    ),
}


# --------------------------------------------------------------------------- #
# JSON-RPC dispatch
# --------------------------------------------------------------------------- #
def handle(req):
    method = req.get("method")
    rid = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        proto = params.get("protocolVersion", DEFAULT_PROTOCOL)
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "protocolVersion": proto,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }

    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no reply

    if method == "ping":
        return {"jsonrpc": "2.0", "id": rid, "result": {}}

    if method == "tools/list":
        tools = [
            {"name": name, "description": desc, "inputSchema": schema}
            for name, (desc, schema, _fn) in TOOLS.items()
        ]
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": tools}}

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        entry = TOOLS.get(name)
        if not entry:
            return {"jsonrpc": "2.0", "id": rid, "result": err_result(f"unknown tool: {name}")}
        _desc, _schema, fn = entry
        try:
            result = fn(args)
        except Exception:
            result = err_result("tool raised:\n" + traceback.format_exc())
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    # unknown method
    if rid is not None:
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"method not found: {method}"}}
    return None


def main():
    log(f"started; repo={REPO_ROOT}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"bad json: {e}")
            continue
        try:
            resp = handle(req)
        except Exception:
            log("handler crash:\n" + traceback.format_exc())
            rid = req.get("id") if isinstance(req, dict) else None
            resp = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "internal error"}}
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
