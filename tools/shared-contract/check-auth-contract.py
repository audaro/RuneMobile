#!/usr/bin/env python3
"""Drift finder for the Jagex OAuth wire contract (OAUTH-1).

Reads auth-contract.json and checks that every pin's value is present in each source file listed in the
pin's `ports`. Whitespace is collapsed before matching, so a value wrapped across two source lines (e.g.
the launcher User-Agent in the .m / .kt) still matches its single-line form in the JSON.

Prints one "[port] pin-id: value" line per drift and exits 2 when any drift is found; on a clean run it
prints an OK summary and exits 0. Called by check-auth-contract.sh (kept as a separate file because
macOS bash 3.2 mis-parses a heredoc inside $() — same reason extract-contract.py is its own file).
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CONTRACT = HERE / "auth-contract.json"


def main() -> int:
    # Fail closed with a clear message (exit 3, matching the "no contract file" convention in the .sh) rather
    # than tracebacking if the JSON is missing / malformed — this is auth-critical tooling run in the gate.
    try:
        doc = json.loads(CONTRACT.read_text())
        sources = doc["sources"]
        pins = doc["pins"]
    except FileNotFoundError:
        print(f"auth contract: no contract file at {CONTRACT}")
        return 3
    except (json.JSONDecodeError, KeyError) as e:
        print(f"auth contract: contract file is malformed ({CONTRACT}): {e}")
        return 3

    collapsed = {}
    findings = []
    for port, rel in sources.items():
        p = ROOT / rel
        if not p.exists():
            findings.append((port, "<file-missing>", rel))
            collapsed[port] = None
            continue
        collapsed[port] = re.sub(r"\s+", " ", p.read_text(encoding="utf-8", errors="replace"))

    for pin in pins:
        # A pin carries either a single "value" or, for strings the ports wrap across source lines with
        # concat glue, a list of "fragments" that must ALL be present (each sits within one source line).
        if "fragments" not in pin and "value" not in pin:
            print(f"auth contract: pin '{pin.get('id', '?')}' has neither 'value' nor 'fragments'")
            return 3
        parts = pin["fragments"] if "fragments" in pin else [pin["value"]]
        needles = [re.sub(r"\s+", " ", part) for part in parts]
        for port in pin["ports"]:
            text = collapsed.get(port)
            if text is None:
                continue  # already reported as a missing file
            missing = [orig for orig, needle in zip(parts, needles) if needle not in text]
            for orig in missing:
                findings.append((port, pin["id"], orig))

    if not findings:
        print(f"auth contract: OK ({len(pins)} pins verified across iOS / Android / script)")
        return 0

    print("auth contract: DRIFT — a pinned Jagex OAuth value is missing from a port that must carry it")
    for port, pin_id, value in findings:
        print(f"    - [{port}] {pin_id}: expected to find  {value}")
    print()
    print("  Fix: restore the value in the port above, or (if Jagex changed it) update auth-contract.json")
    print("  AND every listed port in the same commit.")
    return 2


if __name__ == "__main__":
    sys.exit(main())
