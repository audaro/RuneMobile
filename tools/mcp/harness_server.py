#!/usr/bin/env python3
"""
runelite-ios harness MCP server.

A small stdio MCP (Model Context Protocol) server that exposes the project's
dev-tools harnesses as callable tools, plus two net-new capabilities that the
repo did not have before: a PNG pixel-diff (the long-planned maxChannelDelta
golden compare) and an evidence-catalog indexer.

Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout.
Pinned interpreter: /usr/bin/python3 (system Python — ships PIL + numpy, which
the image_diff tool needs). All other tools are pure stdlib + subprocess.

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

Nothing here is destructive: every tool reads, renders, measures, or flips a
runtime debug knob.
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
import traceback
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_NAME = "runelite-ios-harness"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2024-11-05"


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
    for cand in (
        "/opt/homebrew/opt/openjdk@11",
        "/opt/homebrew/opt/openjdk@21",
        os.environ.get("JAVA_HOME", ""),
    ):
        if cand and Path(cand, "bin", "java").exists():
            return cand
    return None


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
        tokens = REPO_ROOT / "ios/dev-tools/tokens.json"
        if not tokens.exists():
            return err_result(
                "in_game mode needs ios/dev-tools/tokens.json (mint via "
                "ios/dev-tools/fetch-shield-tokens.sh). Use mode=login_screen for no-auth capture."
            )
    else:
        script = REPO_ROOT / "ios/dev-tools/headless/run-headless.sh"
        out_dir = REPO_ROOT / "ios/dev-tools/headless/out"

    if not script.exists():
        return err_result(f"missing script: {script}")

    env = {"RUN_SECONDS": str(run_seconds), "CAPTURE_INTERVAL": str(interval)}
    # boot + (optional) login takes a while; give the script room over its own RUN_SECONDS.
    timeout = max(180, run_seconds + 150)
    rc, out, err = run(["bash", str(script)], cwd=REPO_ROOT, timeout=timeout, env=env)

    frames = sorted(glob.glob(str(out_dir / "frame-*.png")))
    combined = out + "\n" + err
    markers = {}
    m = re.findall(r"nullGraphics=(\d+)", combined)
    if m:
        markers["nullGraphics"] = m[-1]
    m = re.findall(r"gameState=(\w+)", combined)
    if m:
        markers["gameState"] = m[-1]
    markers["frameCount"] = len(frames)

    return ok_result(
        {
            "ok": rc == 0,
            "mode": mode,
            "exitCode": rc,
            "outputDir": str(out_dir),
            "frames": frames[-8:],
            "lastFrame": frames[-1] if frames else None,
            "markers": markers,
            "logTail": "\n".join(combined.strip().splitlines()[-25:]),
            "hint": "Open lastFrame with the Read tool to view it, or pass two frames to image_diff.",
        }
    )


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

    na = np.asarray(ia, dtype=np.int16)
    nb = np.asarray(ib, dtype=np.int16)
    diff = np.abs(na - nb)
    per_pixel = diff.max(axis=2)  # worst channel per pixel
    max_delta = int(diff.max())
    mean_delta = round(float(diff.mean()), 4)
    rmse = round(float(np.sqrt((diff.astype(np.float64) ** 2).mean())), 4)
    pct_diff = round(float((per_pixel > threshold).mean() * 100.0), 4)

    # heatmap: red channel scaled so even small deltas are visible.
    h, w = per_pixel.shape
    amp = np.clip(per_pixel.astype(np.int32) * 4, 0, 255).astype(np.uint8)
    heat = np.zeros((h, w, 3), dtype=np.uint8)
    heat[..., 0] = amp
    heat[..., 2] = (per_pixel > threshold).astype(np.uint8) * 40
    out_path = a.get("out") or str(Path(pa).with_suffix("").as_posix() + ".diff.png")
    Image.fromarray(heat).save(out_path)

    summary = {
        "ok": max_delta <= threshold,
        "width": w,
        "height": h,
        "maxChannelDelta": max_delta,
        "meanChannelDelta": mean_delta,
        "rmse": rmse,
        "pctPixelsDiffering": pct_diff,
        "threshold": threshold,
        "diffImage": out_path,
        "identical": max_delta == 0,
    }

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
    jdk = a.get("jdk") or find_jdk()
    if not jdk:
        return err_result("no JDK found (looked at openjdk@11, openjdk@21, JAVA_HOME).")
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
    results = {}
    for name, ops, ns, ops_s, chk in re.findall(
        r"RESULT (\w+) ops=(\d+) ns=(\d+) opsPerSec=([\d.eE+]+) chk=(-?\d+)", o
    ):
        results[name] = {"ops": int(ops), "ns": int(ns), "opsPerSec": float(ops_s)}
    return ok_result(
        {
            "ok": rc == 0 and bool(results),
            "jdk": jdk,
            "exitCode": rc,
            "results": results,
            "raw": o.strip().splitlines()[-10:],
        }
    )


def tool_glsl_es_validate(a):
    """Run the GLES 3.00 shader-downport validator."""
    script = REPO_ROOT / "ios/dev-tools/headless/glsl_es_repro.py"
    if not script.exists():
        return err_result(f"missing {script}")
    if not shutil.which("glslangValidator"):
        return err_result(
            "glslangValidator not on PATH — install it (brew install glslang) to validate shaders."
        )
    rc, o, e = run(["python3", str(script)], cwd=REPO_ROOT, timeout=120)
    combined = o + "\n" + e
    rows = []
    for mode, stage, status in re.findall(
        r"uiScalingMode=(\w+),\s*(vertex|fragment):\s*(\w+)", combined
    ):
        rows.append({"mode": mode, "stage": stage, "status": status})
    failures = [r for r in rows if r["status"].upper() != "OK"]
    return ok_result(
        {
            "ok": rc == 0 and not failures,
            "exitCode": rc,
            "results": rows,
            "failures": failures,
            "logTail": combined.strip().splitlines()[-20:],
        }
    )


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
    rc, o, er = run(base + ["exec-out", "screencap", "-p"], timeout=30)
    if rc != 0:
        return err_result({"exitCode": rc, "stderr": er[-800:], "hint": "is a device/emulator connected? (adb devices)"})
    # exec-out returns binary on stdout; capture_output text mode would corrupt it, so re-run binary-safe.
    p = subprocess.run(base + ["exec-out", "screencap", "-p"], capture_output=True, timeout=30)
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
    script = REPO_ROOT / "android/dev-tools/gpu/fps-measure.sh"
    if not script.exists():
        return err_result(f"missing {script}")
    seconds = int(a.get("seconds", 20))
    label = a.get("label", "mcp")
    csv = a.get("out_csv") or str(REPO_ROOT / "android/dev-tools/gpu" / f"fps-{label}.csv")
    cmd = ["bash", str(script), "-d", str(seconds), "-o", csv]
    if a.get("serial"):
        cmd += ["-s", a["serial"]]
    cmd += [label]
    rc, o, er = run(cmd, cwd=REPO_ROOT, timeout=seconds + 60)
    combined = o + "\n" + er
    # fps stats come off the "... fps ... mean=.. median=.. min=.. max=.." line.
    stats = {}
    fps_line = next((ln for ln in combined.splitlines() if re.search(r"\bfps\b.*mean=", ln)), "")
    for key in ("mean", "median", "min", "max"):
        m = re.search(rf"{key}[^0-9]*([\d.]+)", fps_line, re.IGNORECASE)
        if m:
            stats[key] = float(m.group(1))
    # frame-time stats (ms) come off the "... frame ... min=.. avg=.. p95~=.. max=.." line — the trustworthy A/B signal.
    frame = {}
    frame_line = next((ln for ln in combined.splitlines() if "frame" in ln and "avg=" in ln), "")
    for key, pat in (("min", r"min=([\d.]+)"), ("avg", r"avg=([\d.]+)"), ("p95", r"p95~?=([\d.]+)"), ("max", r"max=([\d.]+)")):
        m = re.search(pat, frame_line)
        if m:
            frame[key] = float(m.group(1))
    thermal = re.findall(r"thermal\[(\w+)\]: hottest=([\w.]+)C status=(\w+)", combined)
    return ok_result(
        {
            "ok": rc == 0,
            "label": label,
            "exitCode": rc,
            "csv": csv,
            "fps": stats,
            "frameMs": frame,
            "thermal": {w: {"hottestC": h, "status": s} for (w, h, s) in thermal},
            "logTail": combined.strip().splitlines()[-15:],
            "hint": "Flip a preset with android_set_hd_config between two android_fps runs; compare frameMs.avg/p95 (not fps) for a trustworthy A/B.",
        }
    )


def tool_run_verdict(a):
    script = a.get("script")
    log_path = a.get("log")
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
    cmd = ["bash", str(sp)]
    if log_path:
        cmd.append(str((REPO_ROOT / log_path) if not os.path.isabs(log_path) else log_path))
    rc, o, er = run(cmd, cwd=REPO_ROOT, timeout=60)
    combined = o + "\n" + er
    verdict = "UNKNOWN"
    m = re.search(r"\b(GREEN|RED|PASS|FAIL|INCONCLUSIVE)\b", combined)
    if m:
        verdict = m.group(1)
    return ok_result({"ok": rc == 0, "verdict": verdict, "exitCode": rc, "output": combined.strip().splitlines()[-25:]})


# --------------------------------------------------------------------------- #
# tool registry (name -> description, inputSchema, handler)
# --------------------------------------------------------------------------- #
TOOLS = {
    "headless_render": (
        "Run the desktop headless RuneLite capture (real engine, no device) and return the PNG "
        "frames + key log markers (nullGraphics, gameState). mode=login_screen needs no auth; "
        "mode=in_game requires ios/dev-tools/tokens.json. Slow (~1-3 min).",
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
        "Compile (--release 8) and run the jvmbench throughput proxy on desktop OpenJDK; "
        "returns parsed ops/s for floatbits, raster, mixed.",
        {"type": "object", "properties": {"jdk": {"type": "string", "description": "JDK home (optional)"}}},
        tool_jvm_bench,
    ),
    "glsl_es_validate": (
        "Run the GLES 3.00 shader-downport validator (glsl_es_repro.py) across uiScalingMode "
        "variants; returns per-mode OK/FAIL. Catches the implicit-cast regressions GLES forbids.",
        {"type": "object", "properties": {}},
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
        "Run the fps-measure harness for N seconds against a connected device; returns "
        "mean/median/min/max fps. Pair two runs around android_set_hd_config for an A/B.",
        {
            "type": "object",
            "properties": {
                "seconds": {"type": "integer", "default": 20},
                "label": {"type": "string", "default": "mcp"},
                "out_csv": {"type": "string"},
                "serial": {"type": "string"},
            },
        },
        tool_android_fps,
    ),
    "run_verdict": (
        "Run any *-verdict.sh inside the repo against a log file and return its GREEN/RED/PASS/FAIL.",
        {
            "type": "object",
            "properties": {
                "script": {"type": "string", "description": "repo-relative path to a *-verdict.sh"},
                "log": {"type": "string", "description": "log file to adjudicate (optional)"},
            },
            "required": ["script"],
        },
        tool_run_verdict,
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
