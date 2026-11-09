#!/usr/bin/env python3
"""List every Java method the iOS app's native code looks up through JNI, for the simulator bridge census.

Usage: extract-lookups.py [source.m ...] > lookups.tsv

With no arguments it reads every C-family source the RuneMobile target compiles, from ios/app/project.yml, so a
newly added JNI file can't be left out.

Prints one line per distinct lookup, tab-separated: kind, class, member name, JNI signature, and the source lines
that look it up. Kinds: class (FindClass; name and signature are "-"), smethod, method, sfield, field.
run-census-sim.sh hands the list to the app, which checks every line against the running VM.

A lookup's class is the FindClass its class variable came from (directly, or through NewGlobalRef) in the same
function. When the class or the method name is a parameter of that function, the values come from its call sites
(callMain's class, the method accountInvokeVoid runs). Any lookup that can't be resolved this way stops the
extraction with an error, because a lookup left off the list is one the census would report as checked.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PROJECT = REPO / "ios/app/project.yml"
SOURCE_EXT = (".m", ".mm", ".c", ".cpp")

LOOKUP_FNS = {"GetStaticMethodID": "smethod", "GetMethodID": "method", "GetStaticFieldID": "sfield", "GetFieldID": "field"}

# Functions whose lookups take their names from data, not from the source. Literal lookups in them still count.
NAMES_FROM_DATA = {
    "simBridgeCensusRun": "the census itself, which looks up the names in its list",
}

# Classes that are on the classpath only in a test mode.
EXCLUDED_CLASSES = {
    "RouteCL1Probe": "only on the L1 test-mode classpath (routec-l1.jar alone)",
}


FREE_TEXT_DIRECTIVE = re.compile(r"[ \t]*#[ \t]*(?:pragma|warning|error)\b")


class ExtractError(Exception):
    pass


def blank(src):
    """(code, nostr): comments (and #pragma/#warning/#error lines, which are free text) replaced by spaces in
    both; nostr also blanks string and char literal contents. Lengths and newlines are kept, so offsets and line
    numbers match the original."""
    code, nostr = list(src), list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        line_start = i == 0 or src[i - 1] == "\n"
        if src.startswith("//", i) or (line_start and FREE_TEXT_DIRECTIVE.match(src, i)):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                code[k] = nostr[k] = " "
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise ExtractError("unterminated /* comment")
            for k in range(i, j + 2):
                if src[k] != "\n":
                    code[k] = nostr[k] = " "
            i = j + 2
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            if j >= n:
                raise ExtractError(f"unterminated {c} literal at offset {i}")
            for k in range(i + 1, j):
                nostr[k] = "x"
            i = j + 1
        else:
            i += 1
    return "".join(code), "".join(nostr)


def line_of(src, pos):
    return src.count("\n", 0, pos) + 1


def functions(nostr):
    """[(start, end, name, params, static)] for every top-level brace block. name/params are None unless the block
    is a C function body."""
    out, depth, start, boundary = [], 0, None, 0
    for i, c in enumerate(nostr):
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth < 0:
                raise ExtractError(f"unbalanced '}}' at line {line_of(nostr, i)}")
            if depth == 0:
                header = nostr[boundary:start]
                # Only the text after the last top-level ';' belongs to this block.
                header = header[header.rfind(";") + 1 :]
                m = re.search(r"\b(\w+)\s*\(([^()]*)\)\s*$", header)
                name, params = (m.group(1), m.group(2)) if m else (None, None)
                out.append((start, i + 1, name, params, bool(re.search(r"\bstatic\b", header))))
                boundary = i + 1
        elif c == ";" and depth == 0:
            boundary = i + 1
    if depth != 0:
        raise ExtractError("unbalanced braces at end of a file (a brace split across #if branches?)")
    return out


def call_args(code, nostr, open_paren):
    """Argument texts of the call whose '(' is at open_paren, and the offset just past its ')'."""
    depth, args, last = 0, [], open_paren + 1
    for i in range(open_paren, len(nostr)):
        c = nostr[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(code[last:i].strip())
                return args, i + 1
        elif c == "," and depth == 1:
            args.append(code[last:i].strip())
            last = i + 1
    raise ExtractError(f"unclosed call at line {line_of(nostr, open_paren)}")


def literal(arg):
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', arg)
    return m.group(1) if m else None


def param_names(params):
    names, depth, cur = [], 0, ""
    for c in params + ",":
        if c in "<([":
            depth += 1
        elif c in ">)]":
            depth -= 1
        if c == "," and depth == 0:
            m = re.search(r"(\w+)\s*$", cur)
            names.append(m.group(1) if m else None)
            cur = ""
        else:
            cur += c
    return names


def is_declaration(nostr, pos):
    """True when the name at pos is being declared or defined (a type or '*' precedes it), not called."""
    before = nostr[:pos].rstrip()
    if before.endswith("*"):
        return True
    m = re.search(r"(\w+)$", before)
    return bool(m) and m.group(1) not in ("return", "else", "do", "case")


def call_site_values(code, nostr, fname, index, skip, file):
    """The literal at argument `index` of every call to fname outside its definition [skip)."""
    values = []
    for m in re.finditer(r"\b" + re.escape(fname) + r"\s*\(", nostr):
        if skip[0] <= m.start() < skip[1] or is_declaration(nostr, m.start()):
            continue
        args, _ = call_args(code, nostr, m.end() - 1)
        v = literal(args[index]) if index < len(args) else None
        if v is None:
            raise ExtractError(f"{file}:{line_of(nostr, m.start())}: {fname}(...) argument {index} is not a literal")
        values.append(v)
    if not values:
        raise ExtractError(f"{file}: no call sites of {fname}")
    return values


def extract(path):
    src = Path(path).read_text()
    try:
        code, nostr = blank(src)
        fns = functions(nostr)
    except ExtractError as e:
        raise ExtractError(f"{Path(path).name}: {e}") from None
    sites, skipped = [], []

    def resolve(arg, fn, pos, what):
        """Literal values for a lookup argument: the literal itself, or the call-site literals of a parameter."""
        v = literal(arg)
        if v is not None:
            return [v]
        start, end, name, params, static = fn
        if name in NAMES_FROM_DATA:
            return None
        names = param_names(params) if params else []
        if arg in names:
            # Only a static function's callers are all in this file.
            if not static:
                raise ExtractError(f"{Path(path).name}:{line_of(src, pos)}: the {what} is a parameter of {name}, "
                                   "which isn't static, so its callers can be in other files")
            return call_site_values(code, nostr, name, names.index(arg), (start, end), Path(path).name)
        raise ExtractError(f"{Path(path).name}:{line_of(src, pos)}: the {what} '{arg}' is neither a literal nor a parameter")

    calls = "FindClass|NewGlobalRef|" + "|".join(LOOKUP_FNS)
    # "cls = (*env)->FindClass(...)", optionally behind a cast or a one-word guard: "cls = prev ? (*env)->..."
    pattern = (r"(?:(\w+)\s*=\s*(?:\w+\s*\?\s*)?(?:\(\s*jclass\s*\)\s*)?)?\(\*\w+\)->(" + calls
               + r")\s*\(")
    for fn in fns:
        start, end, fname = fn[:3]
        classes = {}  # class variable -> FindClass argument text, in source order
        for m in re.finditer(pattern, nostr[start:end]):
            pos = start + m.start(2)
            var, call = m.group(1), m.group(2)
            args, _ = call_args(code, nostr, start + m.end() - 1)
            where = f"{Path(path).name}:{line_of(src, pos)}"
            if call == "NewGlobalRef":
                if var and args[1] in classes:
                    classes[var] = classes[args[1]]
                continue
            if call == "FindClass":
                if len(args) != 2:
                    raise ExtractError(f"{where}: FindClass with {len(args)} arguments")
                if var:
                    classes[var] = args[1]
                cls = resolve(args[1], fn, pos, "class")
                if cls is None:
                    skipped.append((where, pos, NAMES_FROM_DATA[fname]))
                else:
                    sites += [("class", c, "-", "-", where, pos) for c in cls]
                continue
            if len(args) != 4:
                raise ExtractError(f"{where}: {call} with {len(args)} arguments")
            cls_arg = classes.get(args[1])
            if cls_arg is None:
                raise ExtractError(f"{where}: can't tell which FindClass '{args[1]}' came from")
            cls = resolve(cls_arg, fn, pos, "class")
            names = resolve(args[2], fn, pos, "member name")
            sig = literal(args[3])
            if cls is None or names is None:
                skipped.append((where, pos, NAMES_FROM_DATA[fname]))
                continue
            if sig is None:
                raise ExtractError(f"{where}: the signature '{args[3]}' is not a literal")
            sites += [(LOOKUP_FNS[call], c, n, sig, where, pos) for c in cls for n in names]

    # Every FindClass and lookup in the file must have been seen by the per-function scan above.
    total = len(re.findall(r"->(?:FindClass|" + "|".join(LOOKUP_FNS) + r")\s*\(", nostr))
    seen = len({s[5] for s in sites} | {s[1] for s in skipped})
    if seen != total:
        raise ExtractError(f"{Path(path).name}: {total} FindClass/lookup calls in the file, {seen} resolved or skipped")
    return sites, skipped


def app_sources():
    """The C-family sources the RuneMobile target compiles: project.yml's source paths, directories walked."""
    lines = PROJECT.read_text().splitlines()
    out = []
    for i, line in enumerate(lines):
        m = re.match(r"\s*- path: (\S+)\s*$", line)
        if not m or (i + 1 < len(lines) and "type: folder" in lines[i + 1]):
            continue
        p = PROJECT.parent / m.group(1)
        if p.is_dir():
            out += sorted(f for f in p.rglob("*") if f.suffix in SOURCE_EXT)
        elif p.suffix in SOURCE_EXT:
            if not p.is_file():
                raise ExtractError(f"project.yml lists {m.group(1)}, which doesn't exist")
            out.append(p)
    if not out:
        raise ExtractError(f"no sources found in {PROJECT}")
    return out


def main(paths):
    paths = paths or app_sources()
    entries, skipped, excluded, nsites = {}, [], [], 0
    for p in paths:
        sites, sk = extract(p)
        nsites += len({s[5] for s in sites})
        skipped += sk
        for kind, cls, name, sig, where, _pos in sites:
            if cls in EXCLUDED_CLASSES:
                excluded.append((where, cls if kind == "class" else f"{cls}.{name}", EXCLUDED_CLASSES[cls]))
                continue
            wheres = entries.setdefault((kind, cls, name, sig), [])
            if where not in wheres:
                wheres.append(where)
    for (kind, cls, name, sig), wheres in sorted(entries.items(), key=lambda e: (e[0][1], e[0][0] != "class", e[0][2:])):
        print("\t".join((kind, cls, name, sig, ",".join(wheres))))
    for where, _pos, why in skipped:
        print(f"skipped {where}: {why}", file=sys.stderr)
    for where, what, why in excluded:
        print(f"excluded {where} {what}: {why}", file=sys.stderr)
    kinds = {}
    for k in entries:
        kinds[k[0]] = kinds.get(k[0], 0) + 1
    print(f"{nsites} call sites -> {len(entries)} distinct lookups ("
          + ", ".join(f"{n} {k}" for k, n in sorted(kinds.items())) + ")", file=sys.stderr)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except ExtractError as e:
        sys.exit(f"!! {e}")
