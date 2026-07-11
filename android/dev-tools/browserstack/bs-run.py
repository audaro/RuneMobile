#!/usr/bin/env python3
"""BrowserStack App Automate driver for the runelite-ios Android real-device gates.

Drives ONE App Automate session on a real device, then fetches its logcat so the existing emulator
gate scripts can verify it on real hardware — same md5 discipline, different target:
  1. (optional) push tokens.json to the app's external files dir  -> arms autologin
  2. launch the app in the requested mode (census mode passes the `--ez census true` intent extra)
  3. let it run `--wait` seconds (boot -> LOGGED_IN -> the GateCensus probe all log to logcat)
  4. pull the device logs (logcat) to `--out`, for android/dev-tools/{a0-login,a1b-gatecensus}/*.sh

SCAFFOLD STATUS (2026-06-07): the REST endpoints (upload, .../devicelogs) and the `deviceLogs`
capability are confirmed against the BrowserStack App Automate docs. The Appium-client specifics marked
"CONFIRM on first live run" below (the `mobile: startActivity` arg key, and the exact getSessionDetails
field names) are best-effort and get nailed down the first time this runs against a real key — there is
no way to verify them here without an App Automate account + outbound network.

Deps:  pip install "Appium-Python-Client>=3"
Creds: BROWSERSTACK_USERNAME, BROWSERSTACK_ACCESS_KEY  (see bs-credentials.env.example)
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.request

try:
    from appium import webdriver
    from appium.options.android import UiAutomator2Options
except ImportError:
    sys.exit('missing dependency: pip install "Appium-Python-Client>=3"')

HUB = "https://hub-cloud.browserstack.com/wd/hub"
API = "https://api-cloud.browserstack.com/app-automate"
PKG = "dev.audaro.runemobile"
ACT = "dev.audaro.runemobile.MainActivity"


def main():
    ap = argparse.ArgumentParser(description="Drive one BrowserStack App Automate gate session.")
    ap.add_argument("--app", required=True, help="bs://... app_url from the /app-automate/upload response")
    ap.add_argument("--device", default="Google Pixel 8", help="a real arm64 device (GLES 3.1+ for the GPU track)")
    ap.add_argument("--os-version", default="14.0")
    ap.add_argument("--mode", choices=["login", "census", "recon"], default="login")
    ap.add_argument("--tokens", help="path to tokens.json to push (arms autologin; skip for recon)")
    ap.add_argument("--wait", type=int, default=150, help="seconds to let the app run before pulling logs")
    ap.add_argument("--out", default="bs-devicelogs.txt")
    ap.add_argument("--build", default="runelite-android")
    args = ap.parse_args()

    user = os.environ["BROWSERSTACK_USERNAME"]
    key = os.environ["BROWSERSTACK_ACCESS_KEY"]

    opts = UiAutomator2Options()
    opts.set_capability("appium:app", args.app)
    opts.set_capability("appium:deviceName", args.device)
    opts.set_capability("appium:platformVersion", args.os_version)
    opts.set_capability("appium:autoGrantPermissions", True)
    opts.set_capability("bstack:options", {
        "userName": user,
        "accessKey": key,
        "projectName": "runelite-ios-android",
        "buildName": args.build,
        "sessionName": "gate-" + args.mode,
        "deviceLogs": "true",   # logcat capture (default true; set explicitly so the devicelogs endpoint is populated)
        "debug": "true",
    })

    print(f"[bs] session start: {args.device} / Android {args.os_version} / mode={args.mode}", flush=True)
    driver = webdriver.Remote(HUB, options=opts)
    info = {}
    try:
        if args.tokens:
            with open(args.tokens, "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            driver.push_file(f"/sdcard/Android/data/{PKG}/files/tokens.json", b64)
            print("[bs] pushed tokens.json -> autologin armed", flush=True)

        extras = "--ez census true" if args.mode == "census" else ""
        # UiAutomator2 forwards `optionalIntentArguments` straight to `am start ...`, so this mirrors the
        # emulator's `adb shell am start ... --ez census true`. CONFIRM the arg key on first run (some
        # client/server versions name it `intentArguments`); fall back to a plain launch if it errors.
        try:
            driver.execute_script("mobile: startActivity", {
                "component": f"{PKG}/{ACT}",
                "optionalIntentArguments": extras,
            })
        except Exception as e:
            print(f"[bs] startActivity with extras failed ({e}); plain launch", file=sys.stderr, flush=True)
            driver.execute_script("mobile: activateApp", {"appId": PKG})

        print(f"[bs] launched (extras='{extras}'); running {args.wait}s ...", flush=True)
        time.sleep(args.wait)
    finally:
        try:
            raw = driver.execute_script('browserstack_executor: {"action": "getSessionDetails"}')
            info = json.loads(raw) if isinstance(raw, str) else (raw or {})
        except Exception as e:
            print(f"[bs] getSessionDetails failed: {e}", file=sys.stderr, flush=True)
        driver.quit()

    # Resolve the logcat URL: prefer the session-details field; else build the documented REST URL from
    # the build + session hashed ids. CONFIRM the exact field names on first run.
    logs_url = info.get("device_logs_url")
    if not logs_url:
        bid = info.get("build_hashed_id")
        sid = info.get("hashed_id")
        if bid and sid:
            logs_url = f"{API}/builds/{bid}/sessions/{sid}/devicelogs"
    if not logs_url:
        print("[bs] ERROR: could not resolve device-logs URL. session details:",
              json.dumps(info)[:800], file=sys.stderr)
        sys.exit(2)

    req = urllib.request.Request(logs_url)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{key}".encode()).decode())
    data = urllib.request.urlopen(req).read()
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"[bs] device logs -> {args.out} ({len(data)} bytes); session={info.get('hashed_id')}", flush=True)
    if info.get("public_url"):
        print(f"[bs] dashboard: {info['public_url']}", flush=True)


if __name__ == "__main__":
    main()
