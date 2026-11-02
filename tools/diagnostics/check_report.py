"""check_report.py - checks a "Share logs" report: every section is there, the engine answered, and nothing from
the account leaks (no tokens.json name or secret, no web token, email or UUID). Used by
ios/dev-tools/diagnostics/sim-report-check.py and android/dev-tools/diagnostics/device-report-check.sh.

  python3 tools/diagnostics/check_report.py <report.txt> --port ios|android [--tokens tokens.json] [--logged-in]
"""
import argparse
import json
import re
import sys
from pathlib import Path

SECTIONS = {
    "ios": ["== Engine ==", "== Crash reports ==", "== App log, this launch ==", "== App log, previous launch ==",
            "== RuneLite client.log =="],
    "android": ["== Engine ==", "== Recent app exits ==", "== Crash reports ==", "== App log (logcat) ==",
                "== RuneLite client.log =="],
}
ENGINE_MARKS = ["RuneLite ", "Client cycle ", "Built-in plugins on (", "Threads ("]
NO_NAME_NOTE = "(No character name was found to take out"
# The key sets of RMRedact collectAccount / Redact.collectAccount.
NAME_KEYS = {"chosen_display_name", "displayName", "display_name"}
SECRET_KEYS = {"session_id", "chosen_account_id", "accountId", "account_id", "access_token", "refresh_token",
               "id_token", "otl_token", "userHash"}
LEAK_SHAPES = {
    "a web token": re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    "an email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    "a UUID": re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"),
}


def account_values(path):
    """(names, secrets) in a tokens.json, the way the app walks it."""
    names, secrets = set(), set()
    try:
        stack = [json.loads(Path(path).read_text())]
    except (OSError, ValueError, TypeError):
        return names, secrets
    while stack:
        node = stack.pop()
        if isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, dict):
            for k, v in node.items():
                if isinstance(v, str) and v:
                    if k in NAME_KEYS:
                        names.add(v)
                    elif k in SECRET_KEYS:
                        secrets.add(v)
                elif isinstance(v, (list, dict)):
                    stack.append(v)
    return names, secrets


def name_pattern(name):
    body = "".join("[ _\u00a0-]" if ch in " _-\u00a0" else re.escape(ch) for ch in name.strip())
    return re.compile(r"(?<![A-Za-z0-9])" + body + r"(?![A-Za-z0-9])", re.IGNORECASE)


def check(report, port, tokens=None, logged_in=False):
    """(problems, names, secrets): what is wrong with `report` (a list of strings, empty when it passes)."""
    problems = []
    if not report.startswith("RuneMobile diagnostics report\n"):
        problems.append("the report doesn't start with its title")
    for s in SECTIONS[port]:
        if s not in report:
            problems.append(f"missing section {s}")
    engine = report.split("== Engine ==", 1)[-1].split("\n== ", 1)[0]
    for m in ENGINE_MARKS:
        if m not in engine:
            problems.append(f"the engine section has no {m.strip()!r} (engine said: {engine.strip()[:160]!r})")
    if "(no file)" in report.split("== RuneLite client.log ==", 1)[-1][:200]:
        problems.append("client.log wasn't found")
    names, secrets = account_values(tokens) if tokens else (set(), set())
    if logged_in and not names:
        problems.append(f"logged in, but {tokens} has no character name")
    for n in names:
        if name_pattern(n).search(report):
            problems.append("a character name from tokens.json is in the report")
    for v in secrets:
        if len(v) >= 6 and v in report:
            problems.append("a secret from tokens.json is in the report")
    for what, rx in LEAK_SHAPES.items():
        m = rx.search(report)
        if m:
            line = report[report.rfind("\n", 0, m.start()) + 1:report.find("\n", m.end())]
            problems.append(f"{what} is in the report: {line[:160]!r}")
    if not names and NO_NAME_NOTE not in report[:400]:
        problems.append("nothing was taken out, but the report doesn't say so at the top")
    return problems, names, secrets


def main():
    ap = argparse.ArgumentParser(description="Check a Share logs report.")
    ap.add_argument("report")
    ap.add_argument("--port", choices=sorted(SECTIONS), required=True)
    ap.add_argument("--tokens", help="the tokens.json the app had when it made the report")
    ap.add_argument("--logged-in", action="store_true", help="fail when the tokens file holds no name")
    a = ap.parse_args()
    report = Path(a.report).read_text(encoding="utf-8")
    problems, names, secrets = check(report, a.port, a.tokens, a.logged_in)
    if problems:
        print("SHARE_LOGS_REPORT_RED")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"SHARE_LOGS_REPORT_GREEN {len(report.encode('utf-8')) >> 10} KB, {len(names)} names and "
          f"{len(secrets)} secrets checked absent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
