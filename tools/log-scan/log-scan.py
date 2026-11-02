#!/usr/bin/env python3
"""log-scan.py - sort a run's warnings, errors and exceptions into known noise and new problems.

  tools/log-scan/log-scan.py --sim <Documents>/jvm-stdio.log --sim <Documents>/hello-shell.log
  tools/log-scan/log-scan.py --phone ios/app/evidence/device-pull/<stamp>/jvm-stdio.log
  tools/log-scan/log-scan.py --android pixel.txt     # adb logcat -d -v threadtime -s jvm-stdout:*
  tools/log-scan/log-scan.py --desktop ios/dev-tools/headless/out/run-cacio.log
  --noise <file> picks the noise list (default: known-noise.json here), --json <file> writes the full result,
  --suggest prints a noise-entry stub for each new signature.

An event is a logback WARN/ERROR line, a java.util.logging SEVERE/WARNING line, an exception printed on its own,
a [bridge-fault]/[json-fault] line, a fatal VM error, a HotSpot "VM warning", Caciocavallo's "NOT YET IMPLEMENTED",
or a native shell line that says FAILED. The lines after it (the throwable, its stack frames, "Caused by:") belong
to it. Events are grouped by signature: the header and the exception chain with the timestamp and thread dropped
and numbers and hashes blanked, so the same problem on another thread or at another time is one signature.

Each known-noise entry names a header regex, optionally a cause regex (matched against the throwable and every
"Caused by:" line) and the sources it applies to, and says why the line is expected. An event that no entry
covers is NEW and turns the scan RED; so does an input that is missing, empty, or not a log of the kind named.

Separately, ERROR-level events that mention a shader are counted (shaderErrors=N): the gate requires 0 whatever
the noise list says. Exits 0 exactly when GREEN (1 RED, 2 bad input); the last line is
VERDICT: LOG_SCAN_GREEN or _RED. Plain python3, no packages.
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_NOISE = HERE / "known-noise.json"
SOURCES = ("sim", "phone", "android", "desktop")
MAX_ORIGINS_SHOWN = 30

# adb logcat -v threadtime: "10-23 00:18:34.994 17413 17646 I jvm-stdout: <line>"
LOGCAT = re.compile(r"^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+\d+\s+\d+\s+[VDIWEFA]\s+(?P<tag>[^:]*?)\s*: ?(?P<msg>.*)$")
# logback, as RuneLite configures it: "2026-10-22 21:28:47 PDT [main] WARN  n.r.client.Foo - message"
LOGBACK = re.compile(r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:[.,]\d+)?)(?: [A-Za-z][\w/+-]*)? "
                     r"\[(?P<thread>[^\]]*)\] (?P<level>[A-Z]+)\s+(?P<rest>.*)$")
# java.util.logging prints a date line, then "SEVERE: message".
JUL_DATE = re.compile(r"^[A-Z][a-z]{2} \d{1,2}, \d{4} \d{1,2}:\d\d:\d\d [AP]M ")
JUL_LEVEL = re.compile(r"^(?P<level>SEVERE|WARNING): (?P<msg>.*)$")
# A tagged native line: "[jvm] ...", "[faultdiag:pre-clear] ...".
TAG_LINE = re.compile(r"^\[[A-Za-z][\w:.+-]*\]")
EXCEPTION = re.compile(r"^(?:Exception in thread \"[^\"]*\" )?(?:[a-zA-Z_$][\w$]*\.)+[A-Z][\w$]*"
                       r"(?:Exception|Error|Throwable)(?::\s.*)?$")
FRAME = re.compile(r"^\s+at \S|^\s*\.\.\. \d+ (?:more|common frames omitted)")
CAUSE = re.compile(r"^\s*(?:Caused by|Suppressed): ")
# Lines that are an event on their own, whatever precedes them.
OWN_EVENTS = (
    ("FAULT", re.compile(r"\[(?:bridge|json)-fault\]")),
    ("FATAL", re.compile(r"\bFATAL\b|A fatal error has been detected|An error report file with more information is saved")),
    ("WARN", re.compile(r"\bVM warning: ")),
    ("WARN", re.compile(r"NOT YET IMPLEMENTED")),
    ("FAILED", re.compile(r"^\[[A-Za-z][\w:.+-]*\] .*(?:\bFAILED\b|\bfailed\b[: ]|did not survive|boot-failure)")),
)
EVENT_LEVELS = ("WARN", "ERROR", "FATAL")
SHADER = re.compile(r"shader", re.I)


class InputError(Exception):
    pass


def squash(s):
    return " ".join(s.split())


def normalize(s):
    """The part of a line that stays the same from run to run."""
    s = re.sub(r"0x[0-9a-fA-F]+", "0x_", s)
    s = re.sub(r"@[0-9a-f]{5,}\b", "@_", s)
    s = re.sub(r"\d+", "N", s)
    return squash(s)


def read_lines(path, source):
    """The file's lines as the app wrote them; for logcat, only the jvm-stdout lines, prefix removed."""
    try:
        text = Path(path).read_text(errors="replace")
    except OSError as e:
        raise InputError(f"can't read {path}: {e.strerror}")
    lines = text.splitlines()
    if not lines:
        raise InputError(f"{path} is empty")
    if source != "android":
        return [(i, ln) for i, ln in enumerate(lines, 1)]
    out = []
    for i, ln in enumerate(lines, 1):
        m = LOGCAT.match(ln)
        if m and m.group("tag") == "jvm-stdout":
            out.append((i, m.group("msg")))
    if not out:
        raise InputError(f"{path} has no 'jvm-stdout' lines in adb logcat -v threadtime format")
    return out


def own_event(line):
    for level, rx in OWN_EVENTS:
        if rx.search(line):
            return level
    return None


def parse_events(path, source):
    """Every event in one file: dicts with level, header, causes, body, file, line, source."""
    events = []
    cur = None

    def start(level, header, line_no, causes=()):
        ev = {"level": level, "header": squash(header), "causes": [squash(c) for c in causes], "body": 0,
              "frames": 0, "file": str(path), "line": line_no, "source": source}
        events.append(ev)
        return ev

    for line_no, line in read_lines(path, source):
        m = LOGBACK.match(line)
        if m:
            level = m.group("level")
            cur = start(level, f"{level} {m.group('rest')}", line_no) if level in EVENT_LEVELS else None
            continue
        m = JUL_LEVEL.match(line)
        if m:
            cur = start(m.group("level"), line, line_no)
            continue
        if JUL_DATE.match(line):
            cur = None
            continue
        level = own_event(line)
        if level:
            cur = start(level, line, line_no)
            continue
        if TAG_LINE.match(line):
            cur = None
            continue
        if cur is not None:
            if FRAME.match(line):
                cur["frames"] += 1
            elif CAUSE.match(line):
                cur["causes"].append(squash(line))
            elif EXCEPTION.match(line) and cur["frames"] == 0 and not cur["causes"]:
                cur["causes"].append(squash(line))  # the throwable a logged line carries
            elif EXCEPTION.match(line) and cur["frames"] > 0:
                cur = start("EXCEPTION", line, line_no, [line])  # a second trace printed right after the first
            else:
                cur["body"] += 1  # a multi-line message, e.g. a shader compiler's log
            continue
        if EXCEPTION.match(line):
            cur = start("EXCEPTION", line, line_no, [line])
    return events


def signature(ev):
    return " | ".join([normalize(ev["header"])] + [normalize(c) for c in ev["causes"]])


def origin(ev):
    """What logged it, for grouping the report: 'ERROR n.r.c.Foo' for a logback line, else the kind of line. A
    failing GPU shader is logged one source line per ERROR, so one logger can account for hundreds of signatures."""
    m = re.match(r"^((?:WARN|ERROR|FATAL) \S+) - ", ev["header"])
    if m:
        return m.group(1)
    if ev["level"] == "EXCEPTION":
        return "EXCEPTION " + ev["header"].split(":")[0].split()[-1]
    m = TAG_LINE.match(ev["header"])
    return f"{ev['level']} {m.group(0)}" if m else ev["level"]


def is_shader_error(ev):
    return ev["level"] in ("ERROR", "EXCEPTION", "SEVERE", "FATAL") and any(
        SHADER.search(t) for t in [ev["header"]] + ev["causes"])


def load_noise(path):
    try:
        doc = json.loads(Path(path).read_text())
    except OSError as e:
        raise InputError(f"can't read the noise list {path}: {e.strerror}")
    except ValueError as e:
        raise InputError(f"the noise list {path} is not valid JSON: {e}")
    entries = doc.get("noise") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        raise InputError(f"{path}: expected an object with a 'noise' list")
    seen = set()
    out = []
    for n, e in enumerate(entries, 1):
        where = f"{path}: entry {n}"
        if not isinstance(e, dict):
            raise InputError(f"{where} is not an object")
        for k in ("id", "header", "reason"):
            if not isinstance(e.get(k), str) or not e[k].strip():
                raise InputError(f"{where} needs a non-empty '{k}'")
        if e["id"] in seen:
            raise InputError(f"{where}: id '{e['id']}' is used twice")
        seen.add(e["id"])
        unknown = set(e) - {"id", "header", "cause", "sources", "reason"}
        if unknown:
            raise InputError(f"{where} ({e['id']}): unknown field(s) {', '.join(sorted(unknown))}")
        sources = e.get("sources", list(SOURCES))
        if not isinstance(sources, list) or not sources or any(s not in SOURCES for s in sources):
            raise InputError(f"{where} ({e['id']}): 'sources' must be a non-empty list of {', '.join(SOURCES)}")
        try:
            header = re.compile(e["header"])
            cause = re.compile(e["cause"]) if e.get("cause") is not None else None
        except re.error as x:
            raise InputError(f"{where} ({e['id']}): bad regex: {x}")
        out.append({"id": e["id"], "header": header, "cause": cause, "sources": set(sources),
                    "reason": e["reason"]})
    return out


def match_noise(ev, noise):
    for n in noise:
        if ev["source"] not in n["sources"] or not n["header"].search(ev["header"]):
            continue
        if n["cause"] is None or any(n["cause"].search(c) for c in ev["causes"]):
            return n["id"]
    return None


def scan(inputs, noise):
    """inputs: [(source, path)]. The result dict log-scan prints and --json writes."""
    files, events = [], []
    for source, path in inputs:
        evs = parse_events(path, source)
        files.append({"file": str(path), "source": source, "events": len(evs),
                      "shaderErrors": sum(map(is_shader_error, evs))})
        events.extend(evs)
    noise_hits = {n["id"]: 0 for n in noise}
    new = {}
    shader = 0
    for ev in events:
        shader += is_shader_error(ev)
        nid = match_noise(ev, noise)
        if nid:
            noise_hits[nid] += 1
            continue
        sig = signature(ev)
        g = new.setdefault(sig, {"signature": sig, "origin": origin(ev), "count": 0, "level": ev["level"],
                                 "sources": [],
                                 "first": {k: ev[k] for k in ("file", "line", "source", "header", "causes")}})
        g["count"] += 1
        if ev["source"] not in g["sources"]:
            g["sources"].append(ev["source"])
    # Dict order is first-seen order (files in the order given): the first new line is usually the root cause.
    new_list = list(new.values())
    return {
        "files": files,
        "events": len(events),
        "noise": [{"id": n["id"], "count": noise_hits[n["id"]], "reason": n["reason"]} for n in noise],
        "new": new_list,
        "newEvents": sum(g["count"] for g in new_list),
        "shaderErrors": shader,
        "green": not new_list,
    }


def suggest(g):
    """A noise-entry stub for a new signature; the reason is for a person to write."""
    def esc(s):
        return re.sub(r"\d+", r"\\d+", re.escape(s).replace("\\ ", " ").replace("\\-", "-"))

    stub = {"id": "TODO", "header": "^" + esc(g["first"]["header"][:200]), "sources": g["sources"],
            "reason": "TODO: what this is and why it is expected"}
    if g["first"]["causes"]:
        stub["cause"] = esc(g["first"]["causes"][0][:160])
    return json.dumps(stub)


def report_new(res, show_suggest):
    """The new signatures grouped by what logged them, groups in first-seen order."""
    groups = {}
    for g in res["new"]:
        groups.setdefault(g["origin"], []).append(g)
    lines = [f"NEW: {len(res['new'])} signature(s), {res['newEvents']} event(s), from {len(groups)} origin(s)"]
    for n, (org, sigs) in enumerate(groups.items()):
        if n == MAX_ORIGINS_SHOWN:
            lines.append(f"   ... and {len(groups) - MAX_ORIGINS_SHOWN} more origin(s) (see --json)")
            break
        f = sigs[0]["first"]
        lines.append(f"   {org}: {sum(g['count'] for g in sigs)} event(s), {len(sigs)} signature(s), "
                     f"first at {f['file']}:{f['line']}")
        for g in sigs[:3]:
            lines.append(f"      {g['count']:>4}x {g['first']['header'][:220]}")
            for c in g["first"]["causes"][:3]:
                lines.append(f"            {c[:220]}")
            if show_suggest:
                lines.append(f"            suggest: {suggest(g)}")
        if len(sigs) > 3:
            lines.append(f"      +{len(sigs) - 3} more signature(s) from {org}")
    return lines


def report(res, show_suggest):
    lines = [f"log-scan: {len(res['files'])} file(s), {res['events']} events"]
    for f in res["files"]:
        lines.append(f"   {f['source']:<8} {f['events']:>5} events  {f['file']}")
    hit = [n for n in res["noise"] if n["count"]]
    lines.append(f"known noise: {sum(n['count'] for n in hit)} events, {len(hit)} of {len(res['noise'])} entries")
    for n in hit:
        lines.append(f"   {n['count']:>5}  {n['id']}")
    unused = [n["id"] for n in res["noise"] if not n["count"]]
    if unused:
        lines.append(f"   not seen this run: {', '.join(unused)}")
    lines.append(f"shaderErrors={res['shaderErrors']}")
    if res["new"]:
        lines.extend(report_new(res, show_suggest))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sort a run's warnings and errors into known noise and new problems.")
    for s in SOURCES:
        ap.add_argument(f"--{s}", action="append", default=[], metavar="FILE", help=f"a {s} log")
    ap.add_argument("--noise", default=str(DEFAULT_NOISE), help="the known-noise list (JSON)")
    ap.add_argument("--json", metavar="FILE", help="write the full result here")
    ap.add_argument("--suggest", action="store_true", help="print a noise-entry stub for each new signature")
    args = ap.parse_args(argv)
    inputs = [(s, p) for s in SOURCES for p in getattr(args, s)]
    try:
        if not inputs:
            raise InputError("no logs given (--sim, --phone, --android or --desktop)")
        res = scan(inputs, load_noise(args.noise))
    except InputError as e:
        print(f"!! {e}")
        print("LOG_SCAN_RED")
        print("VERDICT: LOG_SCAN_RED")
        return 2
    print(report(res, args.suggest))
    if args.json:
        Path(args.json).write_text(json.dumps(res, indent=2) + "\n")
        print(f"json={args.json}")
    word = "GREEN" if res["green"] else "RED"
    print(f"LOG_SCAN_{word} new={len(res['new'])} noise={sum(n['count'] for n in res['noise'])} "
          f"shaderErrors={res['shaderErrors']}")
    print(f"VERDICT: LOG_SCAN_{word}")
    return 0 if res["green"] else 1


if __name__ == "__main__":
    sys.exit(main())
