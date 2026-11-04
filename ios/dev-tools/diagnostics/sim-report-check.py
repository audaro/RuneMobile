"""sim-report-check.py - build a real "Share logs" report in the iOS Simulator and check what is in it.

Launches the installed app with -RMScreenDriver, waits for the login screen (or, with --logged-in, for the game),
has the app write the report (the driver's "report" command, RMDiagnostics reportText) and checks it with
tools/diagnostics/check_report.py: every section is there, the engine answered, nothing from the account leaks,
and with nothing to take out (logged out) the report says so at the top.
Prints SHARE_LOGS_REPORT_GREEN or _RED, and the report's path. Run with /usr/bin/python3 (the harness needs PIL).

  /usr/bin/python3 ios/dev-tools/diagnostics/sim-report-check.py              # build, install, logged out
  /usr/bin/python3 ios/dev-tools/diagnostics/sim-report-check.py --no-build
  /usr/bin/python3 ios/dev-tools/diagnostics/sim-report-check.py --logged-in  # uses the simulator's own login
                                                                                 # (run-sim.sh --desktop-login)
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "ios/dev-tools/sim-screens"))
sys.path.insert(0, str(REPO / "tools/diagnostics"))
import check_report  # noqa: E402
import screendriver as sd  # noqa: E402
from screendriver import hs  # noqa: E402

def main():
    ap = argparse.ArgumentParser(description="Check a real Share logs report from the iOS Simulator.")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--jars", action="store_true")
    ap.add_argument("--logged-in", action="store_true",
                    help="keep the simulator's login (run-sim.sh --desktop-login) and wait for the game")
    args = ap.parse_args()

    udid, err = hs._sim_udid({"sim_udid": os.environ.get("SIM_UDID")})
    if not udid:
        print(f"SHARE_LOGS_REPORT_RED no simulator: {err}")
        return 1
    try:
        sd.install(udid, no_build=args.no_build, jars=args.jars)
        drv = sd.Driver(udid)
        launch_args = ["-rendererPref", "cpu", "-RMAutoPlay", "YES", "-RMScreenDriver", "YES"]
        launch_args += ["-RMAutoLogin", "YES"] if args.logged_in else ["-RMSkipLogin", "YES"]
        drv.cmd_file.unlink(missing_ok=True)
        launched = time.time()
        if subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, hs.IOS_BUNDLE_ID]
                          + launch_args, stdout=subprocess.DEVNULL).returncode != 0:
            raise sd.DriverError("simctl launch failed")
        until = "LOGGED_IN" if args.logged_in else "LOGIN_SCREEN"
        ok, details = hs._sim_wait(udid, until, 300, since=launched)
        if not ok:
            raise sd.DriverError(f"the app didn't reach {until}: {details.get('reason')}")
        time.sleep(sd.BOOT_SETTLE)
        ok, why, _seq = drv.open("report")
        if not ok:
            raise sd.DriverError(f"report command failed: {why}")
    except sd.DriverError as e:
        print(f"SHARE_LOGS_REPORT_RED {e}")
        return 1

    report_path = drv.docs / "screen-report.txt"
    report = report_path.read_text(encoding="utf-8")
    support = drv.docs.parent / "Library/Application Support"
    tokens = support / ("tokens.json" if args.logged_in else "tokens-skiplogin.json")
    problems, names, secrets = check_report.check(report, "ios", tokens, args.logged_in)
    if args.logged_in and not names:
        problems.append("was run-sim.sh --desktop-login used?")

    size_kb = len(report.encode("utf-8")) >> 10
    if problems:
        print("SHARE_LOGS_REPORT_RED")
        for p in problems:
            print(f"  - {p}")
    else:
        print(f"SHARE_LOGS_REPORT_GREEN {size_kb} KB, {len(names)} names and {len(secrets)} secrets checked absent")
    print(f"report: {report_path}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
