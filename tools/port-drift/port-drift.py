#!/usr/bin/env python3
"""port-drift.py - where the iOS and Android ports differ, read from their source.

  tools/port-drift/port-drift.py                              # the report, as Markdown, on stdout
  tools/port-drift/port-drift.py --out build/port-drift.md
  tools/port-drift/port-drift.py --ios-log <Documents>/hello-shell.log --android-log logcat.txt

Three comparisons, each against something both ports share:
  1. RLHD overrides: the GLSL and Java files each port lays over the same pinned 117HD tree.
  2. JVM options: the options each port's boot path can pass, and the shared-contract flags among them.
  3. Bridge bindings: the Java members each port's native code looks up through JNI, against the shared
     contract's public-static bridge API.

It lists differences and doesn't judge them: many are deliberate. --ios-log and --android-log add the options one
real launch passed (hello-shell.log's "[jvm] opt[N] = ..." lines, logcat's jvm-boot "opt[N] = ..." lines); an
option in a log that the source scan didn't find stops the run, because the scan would then be missing something.
Exits 0 with a report, or 2 when an input is missing or the source has a shape the extractors don't handle: they
stop rather than leave a lookup or an option out.
"""
import argparse
import difflib
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CONTRACT = REPO / "tools/shared-contract/baseline.txt"
IOS_EXTRACTOR = REPO / "ios/dev-tools/bridge-census/extract-lookups.py"
PORTS = ("ios", "android")
NAMES = {"ios": "iOS", "android": "Android"}

# 1. RLHD overrides: (kind, port, overlay dir, where its files land under the jar root, pristine root in rlhd-src).
OVERRIDES = [
    ("GLSL", "ios", "ios/dev-tools/gpu-zone/ios-overrides", "rs117/hd/", "src/main/resources"),
    ("GLSL", "android", "android/dev-tools/gpu/shader-overlay", "", "src/main/resources"),
    ("Java", "ios", "ios/dev-tools/gpu-zone/java-overrides", "", "src/main/java"),
    ("Java", "android", "android/dev-tools/gpu/java-overlay", "", "src/main/java"),
]
OVERRIDE_EXT = {"GLSL": ".glsl", "Java": ".java"}
# Each port's stager (which pins RLHD_REV) and the vendored tree it lays the overrides over.
RLHD = {
    "ios": ("ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh", "ios/dev-tools/gpu-zone/rlhd-src"),
    "android": ("android/dev-tools/gpu/stage-rlhd-zone-jar.sh", "android/dev-tools/gpu/rlhd-src"),
}

# 2. The boot path: (file, declaration regex, the bracket its body opens with, name in the report). Options
# anywhere else in the port's source belong to test modes and are listed, not compared.
BOOT_PATH = {
    "ios": [("ios/app/RuneMobile/JVMLauncher.m", r"^- \(int\)runProbesWithLog:", "{", "runProbesWithLog:")],
    "android": [
        ("android/app/src/main/java/dev/audaro/runemobile/MainActivity.kt", r"\bfun bootJvm\(", "{", "bootJvm"),
        ("android/app/src/main/java/dev/audaro/runemobile/JagexTokens.kt", r"\bval loginOpts\b", "(", "loginOpts"),
        ("android/app/src/main/java/dev/audaro/runemobile/JagexTokens.kt", r"\bval playerLoginOpts\b", "(", "playerLoginOpts"),
        ("android/app/src/main/java/dev/audaro/runemobile/JagexTokens.kt", r"\bval devAutologinOpts\b", "(", "devAutologinOpts"),
        ("android/app/src/main/cpp/jvm_bootstrap.cpp", r"^static void \*jvmThreadMain\(", "{", "jvmThreadMain"),
    ],
}
ANDROID_KOTLIN = "android/app/src/main/java"
ANDROID_CPP = "android/app/src/main/cpp"
OPTION = re.compile(r"-D[A-Za-z_][\w.\-]*(=.*)?|-X\S+|--(add|enable)-\S+|-(ea|da)(:\S+)?|-javaagent:\S+|-verbose:\S+")
OPT_LINE = {
    "ios": re.compile(r"^\[jvm\] opt\[\d+\] = (.*)$"),
    "android": re.compile(r"\bjvm-boot\s*:\s*opt\[\d+\] = (.*)$"),
}

# 3. Android lookups. midOpt(env, cls, name, sig) is a GetStaticMethodID wrapper: its call sites are the lookups.
ANDROID_WRAPPERS = {"midOpt": ("smethod", 1, 2, 3)}
# Functions whose lookups take their names from data at run time, not from the source.
ANDROID_FROM_DATA = {"jvmThreadMain": "the main class comes from MainActivity's launch arguments"}
LOOKUP_FNS = {"GetStaticMethodID": "smethod", "GetMethodID": "method", "GetStaticFieldID": "sfield", "GetFieldID": "field"}
BRIDGE_PACKAGES = ("net/runelite/client/headless", "")  # where the contract's classes live (awtsmoke's are unpackaged)


class InputError(Exception):
    pass


_EL = None


def el():
    """The iOS census's lookup extractor, loaded as a module: its parser and its list of the iOS lookups."""
    global _EL
    if _EL is None:
        if not IOS_EXTRACTOR.is_file():
            raise InputError(f"missing {IOS_EXTRACTOR.relative_to(REPO)}")
        spec = importlib.util.spec_from_file_location("extract_lookups", IOS_EXTRACTOR)
        _EL = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_EL)
    return _EL


def rel(p):
    return str(Path(p).resolve().relative_to(REPO))


def git(*args):
    p = subprocess.run(["git", "-C", str(REPO)] + list(args), capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ""


# ---- 1. RLHD overrides --------------------------------------------------------------------------------------------

def rlhd_rev(port):
    stager, tree = (REPO / p for p in RLHD[port])
    m = re.search(r"^RLHD_REV=([0-9a-f]{40})\s*$", stager.read_text(), re.M) if stager.is_file() else None
    if not m:
        raise InputError(f"no RLHD_REV= line in {RLHD[port][0]}")
    if (tree / "src/.rev").is_file():
        on_disk = (tree / "src/.rev").read_text().strip()
    elif (tree / ".git").exists():
        on_disk = subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if subprocess.run(["git", "-C", str(tree), "status", "--porcelain"], capture_output=True, text=True).stdout.strip():
            raise InputError(f"{RLHD[port][1]} has local changes, so it isn't the pristine tree; restore it first")
    else:
        raise InputError(f"{RLHD[port][1]} is missing; the port's stager ({RLHD[port][0]}) fetches it")
    if on_disk != m.group(1):
        raise InputError(f"{RLHD[port][1]} is at {on_disk[:10] or '?'} but {RLHD[port][0]} pins {m.group(1)[:10]}; "
                         "run the stager to re-provision it")
    return m.group(1)


def code_lines(text):
    """The text's non-blank lines with comments removed (string literals kept), for comparing code, not prose."""
    nostr, strings = lex(text, directives=False)
    out = list(nostr)
    for start, end, _t in strings:
        out[start:end] = text[start:end]
    return [ln.rstrip() for ln in "".join(out).splitlines() if ln.strip()]


def changed(a, b):
    """(added, removed) code lines going from text a to text b."""
    plus = minus = 0
    for line in difflib.unified_diff(code_lines(a), code_lines(b), lineterm="", n=0):
        if line.startswith("+") and not line.startswith("+++"):
            plus += 1
        elif line.startswith("-") and not line.startswith("---"):
            minus += 1
    return plus, minus


def overrides():
    revs = {port: rlhd_rev(port) for port in PORTS}
    files = {}  # (kind, path under the jar or source root) -> {port: overlay file}
    for kind, port, d, prefix, pristine in OVERRIDES:
        root = REPO / d
        if not root.is_dir():
            raise InputError(f"missing override directory {d}")
        for f in sorted(root.rglob("*" + OVERRIDE_EXT[kind])):
            files.setdefault((kind, prefix + f.relative_to(root).as_posix()), {})[port] = f
    rows = []
    for (kind, path), have in sorted(files.items()):
        pristine_root = next(p for k, port, _d, _x, p in OVERRIDES if k == kind)
        row = {"kind": kind, "path": path, "ports": {}}
        for port, f in have.items():
            base = REPO / RLHD[port][1] / pristine_root / path
            text = f.read_text(errors="replace")
            row["ports"][port] = {
                "file": rel(f),
                "vsPristine": changed(base.read_text(errors="replace"), text) if base.is_file() else None,
                "last": git("log", "-1", "--format=%h %s", "--", rel(f)),
                "text": text,
            }
        if len(have) == 2:
            i, a = row["ports"]["ios"]["text"], row["ports"]["android"]["text"]
            row["between"] = changed(i, a)
            row["identical"] = i == a
        rows.append(row)
    return revs, rows


# ---- 2. JVM options -----------------------------------------------------------------------------------------------

def lex(src, kotlin=False, directives=True):
    """(nostr, strings): nostr is src with comments and the contents of string and char literals blanked, newlines
    kept so offsets and lines match; strings is [(start, end, text)] for each string literal outside a comment,
    text being what's between the quotes (a Kotlin template's expressions included as written). C-family
    #pragma/#warning/#error lines are free text and blanked like comments unless directives is False."""
    out, strings, n = list(src), [], len(src)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def skip_char(i):
        m = re.match(r"'(?:\\.[^']{0,6}|[^'\\\n])'", src[i:])
        return i + m.end() if m else i + 1

    def skip_template(j):  # j is just past "${"; returns the offset past its closing "}"
        depth = 1
        while j < n:
            c = src[j]
            if c == '"':
                j = skip_string(j)[0]
                continue
            if c == "'":
                j = skip_char(j)
                continue
            depth += c == "{"
            depth -= c == "}"
            j += 1
            if depth == 0:
                return j
        raise InputError(f"unterminated ${{...}} template at line {src.count(chr(10), 0, j) + 1}")

    def skip_string(i):  # i is at the opening quote; returns (offset past the closing quote, quote length)
        q = 3 if kotlin and src.startswith('"""', i) else 1
        j = i + q
        while j < n:
            if q == 3 and src.startswith('"""', j):
                while j + 3 < n and src[j + 3] == '"':  # a raw string ends at the last quote of a run
                    j += 1
                return j + 3, q
            c = src[j]
            if q == 1 and c == "\\":
                j += 2
            elif q == 1 and c == '"':
                return j + 1, q
            elif q == 1 and c == "\n":
                break
            elif kotlin and src.startswith("${", j):
                j = skip_template(j + 2)
            else:
                j += 1
        raise InputError(f"unterminated string at line {src.count(chr(10), 0, i) + 1}")

    i = 0
    while i < n:
        line_start = i == 0 or src[i - 1] == "\n"
        if src.startswith("//", i) or (directives and not kotlin and line_start and re.match(r"[ \t]*#[ \t]*(pragma|warning|error)\b", src[i:i + 40])):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise InputError(f"unterminated /* comment at line {src.count(chr(10), 0, i) + 1}")
            blank(i, j + 2)
            i = j + 2
        elif src[i] == '"':
            j, q = skip_string(i)
            strings.append((i, j, src[i + q:j - q]))
            blank(i + q, j - q)
            i = j
        elif src[i] == "'":
            j = skip_char(i)
            blank(i + 1, j - 1)
            i = j
        else:
            i += 1
    return "".join(out), strings


def kotlin_consts(src):
    """name -> value for the simple `const val NAME = 512L` / `val NAME = "x"` constants in a Kotlin file."""
    out = {}
    for m in re.finditer(r'\b(?:const\s+)?val\s+([A-Z][A-Z0-9_]*)\s*(?::\s*\w+)?\s*=\s*(?:(-?\d+)L?|"([^"$\\]*)")\s*$', src, re.M):
        out[m.group(1)] = m.group(2) if m.group(2) is not None else m.group(3)
    return out


def placeholders(text, kotlin, consts):
    """An option literal with its computed parts shown as {expr}, or {...} when the expression is long (resolved
    when a Kotlin constant names them)."""
    if kotlin:
        out, i = [], 0
        while i < len(text):
            if text.startswith("${", i):
                depth, j = 1, i + 2
                while j < len(text) and depth:
                    depth += text[j] == "{"
                    depth -= text[j] == "}"
                    j += 1
                expr = text[i + 2:j - 1].strip()
            else:
                m = re.match(r"\$([A-Za-z_]\w*)", text[i:])
                if not m:
                    out.append(text[i])
                    i += 1
                    continue
                expr, j = m.group(1), i + m.end()
            out.append(consts.get(expr, "{" + (expr if re.fullmatch(r"[\w.]{1,24}", expr) else "...") + "}"))
            i = j
        return "".join(out)
    return re.sub(r"%(?:[-+ 0#]*\d*(?:\.\d+)?)(?:hh|h|ll|l|z|j|t|L)?[@diouxXfFeEgGcsp]", "{}", text)


def option_key(opt):
    """(key, value): options with the same key set the same thing."""
    if opt.startswith("-D"):
        name, eq, value = opt[2:].partition("=")
        return "-D" + name, value if eq else ""
    m = re.match(r"-XX:([+-])(\w+)$", opt)
    if m:
        return "-XX:" + m.group(2), m.group(1)
    m = re.match(r"(-XX:\w+)=(.*)$", opt)
    if m:
        return m.group(1), m.group(2)
    m = re.match(r"(-Xm[sx]|-Xss|-Xmn)(.*)$", opt)
    if m:
        return m.group(1), m.group(2)
    m = re.match(r"(-Xlog|-Xshare|-Xverify):?(.*)$", opt)
    if m:
        return m.group(1), m.group(2)
    return opt, ""  # --add-exports=..., -ea:..., -Xint: present or not


def scope(src, nostr, decl, opener, file):
    m = re.search(decl, src, re.M)
    if not m:
        raise InputError(f"{file}: no declaration matching {decl!r}; update BOOT_PATH in port-drift.py")
    close = {"{": "}", "(": ")"}[opener]
    start = nostr.find(opener, m.end())
    if start < 0:
        raise InputError(f"{file}: no '{opener}' after {decl!r}")
    depth = 0
    for i in range(start, len(nostr)):
        depth += nostr[i] == opener
        depth -= nostr[i] == close
        if depth == 0:
            return m.start(), i + 1
    raise InputError(f"{file}: unbalanced '{opener}' after {decl!r}")


def enclosing(src, pos, kotlin):
    """The name of the function or method an out-of-scope option sits in, for the report."""
    pat = r"\bfun\s+(\w+)" if kotlin else r"^[-+]\s*\([^)]*\)\s*(\w+)|^\w[\w\s\*]*?\b(\w+)\s*\([^;]*$"
    name = "?"
    for m in re.finditer(pat, src[:pos], re.M):
        name = next(g for g in m.groups() if g)
    return name


def port_sources(port):
    if port == "ios":
        return el().app_sources()
    kotlin = sorted((REPO / ANDROID_KOTLIN).rglob("*.kt"))
    return kotlin + android_cpp_sources()


def options_of(port):
    """{key: [(value, where)]} for the boot path, and [(option, where, function)] for options elsewhere."""
    boot = {}  # a file can hold several declarations on the path
    for f, decl, opener, _name in BOOT_PATH[port]:
        boot.setdefault(REPO / f, []).append((decl, opener))
    for f in boot:
        if not f.is_file():
            raise InputError(f"missing {rel(f)}")
    found, elsewhere, compared, sources = {}, [], [], port_sources(port)
    for f in sources:
        src = f.read_text(errors="replace")
        kotlin = f.suffix in (".kt", ".kts")
        nostr, strings = lex(src, kotlin)
        consts = kotlin_consts(src) if kotlin else {}
        spans = [scope(src, nostr, decl, opener, rel(f)) for decl, opener in boot.get(f, ())]
        for start, end, text in strings:
            if not OPTION.fullmatch(text):
                continue
            opt = placeholders(text, kotlin, consts)
            if not kotlin and opt.endswith("=") and re.match(r"\s*\+", nostr[end:end + 8]):
                opt += "{...}"  # C++ "-Dx=" + value
            where = f"{f.name}:{src.count(chr(10), 0, start) + 1}"
            before, after = nostr[max(0, start - 60):start], nostr[end:end + 12]
            if (re.search(r"(==|!=)\s*@?$", before) or re.match(r"\s*(==|!=)", after)
                    or re.search(r"\b(startsWith|endsWith|contains|equals|find|rfind|compare|isEqualToString:|hasPrefix:|"
                                 r"hasSuffix:|containsString:)\s*\(?\s*@?$", before)
                    or re.search(r"\bstrn?cmp\s*\([^()]*$", before)):
                compared.append(where)  # the code tests for this option; it doesn't pass it
                continue
            if any(first <= start < last for first, last in spans):
                key, value = option_key(opt)
                found.setdefault(key, []).append((value, where))
            else:
                elsewhere.append((opt, where, enclosing(src, start, kotlin)))
    for f in boot:
        if f not in sources:
            raise InputError(f"{rel(f)} is on the {NAMES[port]} boot path but not among the sources the port builds")
    if not found:
        raise InputError(f"no options found on the {NAMES[port]} boot path")
    return found, elsewhere, compared


def launch_options(path, port):
    lines = Path(path).read_text(errors="replace").splitlines()
    opts = [m.group(1).strip() for m in map(OPT_LINE[port].search, lines) if m]
    if not opts:
        raise InputError(f"{path}: no JVM option lines ({OPT_LINE[port].pattern}); not an {NAMES[port]} boot log")
    return opts


def contract():
    if not CONTRACT.is_file():
        raise InputError(f"missing {rel(CONTRACT)}")
    methods, flags = set(), set()
    for line in CONTRACT.read_text().splitlines():
        m = re.fullmatch(r"METHOD (\w+)#(\w+)\(([^)]*)\)(?: -> \S+)?", line.strip())
        if m:
            methods.add((m.group(1), m.group(2), m.group(3)))
        elif line.startswith("FLAG "):
            flags.add(line[5:].strip())
        elif line.startswith(("PAYLOAD ", "PAYLOAD-DYNAMIC ")):
            continue  # the JSON keys each bridge emits; not compared here
        elif line.strip() and not line.startswith("#"):
            raise InputError(f"{rel(CONTRACT)}: unexpected line {line!r}")
    if not methods or not flags:
        raise InputError(f"{rel(CONTRACT)} has no METHOD or no FLAG lines")
    return methods, flags


# ---- 3. Bridge bindings -------------------------------------------------------------------------------------------

def android_cpp_sources():
    cm = REPO / ANDROID_CPP / "CMakeLists.txt"
    if not cm.is_file():
        raise InputError(f"missing {rel(cm)}")
    out = []
    for group in re.findall(r"add_library\(\s*\w+\s+(?:SHARED|STATIC|MODULE)\s+([^)]*)\)", cm.read_text()):
        for name in group.split():
            p = REPO / ANDROID_CPP / name
            if not p.is_file():
                raise InputError(f"{rel(cm)} lists {name}, which doesn't exist")
            out.append(p)
    if not out:
        raise InputError(f"no sources in {rel(cm)}")
    return out


def call_sites(code, nostr, fname, skip):
    """The argument lists of every call to fname outside its definition [skip)."""
    E = el()
    out = []
    for m in re.finditer(r"\b" + re.escape(fname) + r"\s*\(", nostr):
        if skip[0] <= m.start() < skip[1] or E.is_declaration(nostr, m.start()):
            continue
        out.append(E.call_args(code, nostr, m.end() - 1)[0])
    return out


def android_lookups(path):
    """[(kind, class, name, sig, where)] and [(where, name, sig, why)] skipped, for one C++ file.

    A lookup's class is the FindClass its class variable came from, through NewGlobalRef and plain assignment, in
    the same function, or failing that the one class the file ever assigns to that (global) variable. A class or
    member name that is a parameter of a static function is taken from each call site of that function, so a
    helper like registerDataPanel(cls, getter) pairs each class with its own getter. Every FindClass and lookup in
    the file has to resolve, be a wrapper's own body, or sit in an ANDROID_FROM_DATA function."""
    E = el()
    src = path.read_text()
    try:
        code, nostr = E.blank(src)
        fns = E.functions(nostr)
    except E.ExtractError as e:
        raise InputError(f"{path.name}: {e}") from None
    calls = "|".join(["FindClass", "NewGlobalRef"] + list(LOOKUP_FNS))
    wrappers = "|".join(ANDROID_WRAPPERS)
    pat = re.compile(r"(?:\b([A-Za-z_][\w.]*)\s*=\s*(?:\(\s*jclass\s*\)\s*)?)?(?:\b\w+->(" + calls + r")|\b(" + wrappers + r"))\s*\(")
    alias = re.compile(r"\b([A-Za-z_][\w.]*)\s*=\s*([A-Za-z_]\w*)\s*;")

    def where(pos):
        return f"{path.name}:{E.line_of(src, pos)}"

    # Pass 1: the classes each variable is assigned, file-wide, for globals cached in one function and used in
    # another. A static helper that stores its class in a field of a parameter (registerDataPanel's p.cls = g)
    # assigns, at each call site, the passed variable's field (g_lootPanel.cls) that call's class.
    assigned = {}
    for fn in fns:
        local = {}
        pnames = E.param_names(fn[3]) if fn[3] else []
        for m in sorted(list(pat.finditer(nostr, fn[0], fn[1])) + list(alias.finditer(nostr, fn[0], fn[1])), key=lambda m: m.start()):
            if m.re is alias:
                if m.group(2) in local:
                    lhs, text = m.group(1), local[m.group(2)]
                    local[lhs] = text
                    assigned.setdefault(lhs, set()).add(text)
                    owner, _, field = lhs.partition(".")
                    if field and owner in pnames and fn[4]:
                        for args in call_sites(code, nostr, fn[2], (fn[0], fn[1])):
                            i = pnames.index(owner)
                            cls = text if E.literal(text) is not None else (
                                args[pnames.index(text)] if text in pnames and pnames.index(text) < len(args) else None)
                            if i < len(args) and cls is not None:
                                assigned.setdefault(f"{args[i].lstrip('&')}.{field}", set()).add(cls)
                continue
            var, call = m.group(1), m.group(2)
            if call in ("FindClass", "NewGlobalRef") and var:
                args = E.call_args(code, nostr, m.end() - 1)[0]
                text = args[0] if call == "FindClass" else local.get(args[0])
                if text is not None:
                    local[var] = text
                    assigned.setdefault(var, set()).add(text)

    sites, skipped, seen = [], [], set()
    total = 0
    for fn in fns:
        start, end, fname, params, static = fn
        pnames = E.param_names(params) if params else []
        local = {}

        def values(texts, pos):
            """[{role: literal}] for the texts of one lookup: one dict, or one per call site of this function."""
            lits = {r: E.literal(t) for r, t in texts.items()}
            need = {r: t for r, t in texts.items() if lits[r] is None}
            if not need:
                return [lits]
            if fname in ANDROID_FROM_DATA:
                return None
            for r, t in need.items():
                if t not in pnames:
                    raise InputError(f"{where(pos)}: the {r} '{t}' is neither a literal nor a parameter of {fname}")
            if not static:
                raise InputError(f"{where(pos)}: the lookup takes its {'/'.join(need)} from {fname}'s parameters, "
                                 "but it isn't static, so its callers can be in other files")
            out = []
            for args in call_sites(code, nostr, fname, (start, end)):
                combo = dict(lits)
                for r, t in need.items():
                    i = pnames.index(t)
                    v = E.literal(args[i]) if i < len(args) else None
                    if v is None:
                        raise InputError(f"{path.name}: a call of {fname}(...) passes a non-literal {r}")
                    combo[r] = v
                out.append(combo)
            if not out:
                raise InputError(f"{path.name}: no call sites of {fname}")
            return out

        for m in sorted(list(pat.finditer(nostr, start, end)) + list(alias.finditer(nostr, start, end)), key=lambda m: m.start()):
            if m.re is alias:
                if m.group(2) in local:
                    local[m.group(1)] = local[m.group(2)]
                continue
            var, call, wrapper = m.group(1), m.group(2), m.group(3)
            pos = m.start(2) if call else m.start(3)
            if wrapper and E.is_declaration(nostr, pos):
                continue
            args = E.call_args(code, nostr, m.end() - 1)[0]
            if call == "NewGlobalRef":
                if var and args[0] in local:
                    local[var] = local[args[0]]
                continue
            total += 1
            if fname in ANDROID_WRAPPERS:  # the wrapper's own lookup: its call sites are counted instead
                seen.add(pos)
                continue
            if call == "FindClass":
                if len(args) != 1:
                    raise InputError(f"{where(pos)}: FindClass with {len(args)} arguments")
                if var:
                    local[var] = args[0]
                got = values({"class": args[0]}, pos)
                if got is None:
                    skipped.append((where(pos), "-", "-", ANDROID_FROM_DATA[fname]))
                else:
                    sites += [("class", v["class"], "-", "-", where(pos)) for v in got]
                seen.add(pos)
                continue
            if wrapper:
                kind, ci, ni, si = ANDROID_WRAPPERS[wrapper]
            else:
                kind, ci, ni, si = LOOKUP_FNS[call], 0, 1, 2
            if len(args) <= max(ci, ni, si):
                raise InputError(f"{where(pos)}: {call or wrapper} with {len(args)} arguments")
            cls_text = local.get(args[ci])
            if cls_text is None:
                globals_ = assigned.get(args[ci], set())
                lit = {t for t in globals_ if E.literal(t) is not None}
                if len(lit) != 1:
                    if fname in ANDROID_FROM_DATA:
                        skipped.append((where(pos), E.literal(args[ni]) or "?", E.literal(args[si]) or "?", ANDROID_FROM_DATA[fname]))
                        seen.add(pos)
                        continue
                    raise InputError(f"{where(pos)}: can't tell which FindClass '{args[ci]}' came from")
                cls_text = lit.pop()
            sig = E.literal(args[si])
            if sig is None:
                raise InputError(f"{where(pos)}: the signature '{args[si]}' is not a literal")
            got = values({"class": cls_text, "name": args[ni]}, pos)
            if got is None:
                skipped.append((where(pos), E.literal(args[ni]) or "?", sig, ANDROID_FROM_DATA[fname]))
            else:
                sites += [(kind, v["class"], v["name"], sig, where(pos)) for v in got]
            seen.add(pos)

    # Every FindClass and lookup call in the file must have been met by the per-function scan above, and must be
    # in the env->Name(...) form it reads: a C-style (*env)->Name(env, ...) call would otherwise go unseen.
    read = {m.start(2) for m in pat.finditer(nostr) if m.group(2)}
    unread = [m.start(1) for m in re.finditer(r"\b(" + calls + r")\s*\(", nostr) if m.start(1) not in read]
    if unread:
        raise InputError(f"{', '.join(where(p) for p in unread)}: a JNI call not in the env->Name(...) form the "
                         "Android extractor reads; extend android_lookups in port-drift.py")
    every = [m for m in pat.finditer(nostr) if m.group(2) != "NewGlobalRef"
             and not (m.group(3) and E.is_declaration(nostr, m.start(3)))]
    if len(every) != total or total != len(seen):
        raise InputError(f"{path.name}: {len(every)} FindClass/lookup calls in the file, {len(seen)} resolved or skipped")
    return sites, skipped


def lookups(port):
    """{(kind, class, name, sig): [where]} and the skipped lookups, for one port."""
    out, skipped = {}, []
    if port == "ios":
        E = el()
        try:
            for p in E.app_sources():
                sites, sk = E.extract(p)
                skipped += [(w, "-", "-", why) for w, _pos, why in sk]
                for kind, cls, name, sig, w, _pos in sites:
                    if cls not in E.EXCLUDED_CLASSES:
                        out.setdefault((kind, cls, name, sig), []).append(w)
        except E.ExtractError as e:
            raise InputError(f"iOS lookups: {e}") from None
    else:
        for p in android_cpp_sources():
            sites, sk = android_lookups(p)
            skipped += sk
            for kind, cls, name, sig, w in sites:
                out.setdefault((kind, cls, name, sig), []).append(w)
    return out, skipped


def java_params(sig):
    """'(Ljava/lang/String;Z[I)V' -> 'String,boolean,int[]', the way the contract writes parameters."""
    prim = {"Z": "boolean", "B": "byte", "C": "char", "S": "short", "I": "int", "J": "long", "F": "float", "D": "double"}
    m = re.match(r"\(([^)]*)\)", sig)
    if not m:
        raise InputError(f"bad JNI signature {sig!r}")
    s, i, out = m.group(1), 0, []
    while i < len(s):
        dims = 0
        while s[i] == "[":
            dims, i = dims + 1, i + 1
        if s[i] == "L":
            j = s.index(";", i)
            t, i = s[i + 1:j].rsplit("/", 1)[-1].replace("$", "."), j + 1
        else:
            t, i = prim[s[i]], i + 1
        out.append(t + "[]" * dims)
    return ",".join(out)


def split_class(internal):
    pkg, _, simple = internal.rpartition("/")
    return pkg, simple


# ---- The report ---------------------------------------------------------------------------------------------------

def md_table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(str(c).replace("|", "\\|") for c in r) + " |" for r in rows]
    return out


def fmt_change(c):
    return "not in RLHD" if c is None else f"+{c[0]}/-{c[1]}"


def report_overrides(revs, rows):
    out = ["## 1. RLHD overrides", ""]
    out.append(f"Both ports pin RLHD `{revs['ios'][:10]}`." if revs["ios"] == revs["android"] else
               f"**The ports pin different RLHD revisions**: iOS `{revs['ios'][:10]}`, Android `{revs['android'][:10]}`.")
    out += ["", "Each port lays its own copies of these files over that tree. Counts are code lines, comments left "
            "out, against the pristine file. Both ports also rewrite shader source when it's compiled (iOS: `RouteCBridge.m` "
            "`downportShaderSource`, Android: `librlawt.cpp` `rc_downport`), so a file only one port overrides may "
            "still be handled on the other. Check there before porting a fix.", ""]
    one, both = [r for r in rows if len(r["ports"]) == 1], [r for r in rows if len(r["ports"]) == 2]
    if one:
        out += ["### Overridden on one port only", ""]
        out += md_table(["File", "Port", "Code vs RLHD", "Last change"],
                        [(f"`{r['path']}`", NAMES[p], fmt_change(d["vsPristine"]), d["last"] or "(uncommitted)")
                         for r in one for p, d in r["ports"].items()])
        out.append("")
    if both:
        out += ["### Overridden on both", ""]
        rows_ = []
        for r in both:
            i, a = r["ports"]["ios"], r["ports"]["android"]
            rel_ = "identical" if r["identical"] else "same code, comments differ" if r["between"] == (0, 0) else \
                f"code differs: +{r['between'][0]}/-{r['between'][1]}"
            rows_.append((f"`{r['path']}`", rel_,
                          fmt_change(i["vsPristine"]), fmt_change(a["vsPristine"])))
        out += md_table(["File", "iOS vs Android", "iOS code vs RLHD", "Android code vs RLHD"], rows_)
        out.append("")
    return out, {"oneOnly": len(one), "both": len(both), "bothDiffer": sum(r["between"] != (0, 0) for r in both)}


def show_values(vals, launched):
    """'`32` (JVMLauncher.m:1774)'. A value the launch passed is marked with a check, and a computed one also shows
    what it came to in that launch when that is short."""
    seen, parts = set(), []
    for value, where in vals:
        if value in seen:
            continue
        seen.add(value)
        text = f"`{value or '(set)'}`"
        if launched:
            rx = re.compile(".*".join(map(re.escape, re.split(r"\{[^{}]*\}", value))) + "$")
            hits = sorted(v for v in launched if rx.match(v))
            if hits:
                text += " ✓"
                short = [h for h in hits if h != value and len(h) <= 40]
                if short:
                    text += " = " + ", ".join(f"`{h}`" for h in short)
        parts.append(f"{text} ({where})")
    return "<br>".join(parts)


def report_options(opts, elsewhere, compared, launches, flags):
    out = ["## 2. JVM options", ""]
    paths = []
    for p in PORTS:
        paths.append(NAMES[p] + " " + ", ".join("`%s` `%s`" % (Path(f).name, name) for f, _d, _o, name in BOOT_PATH[p]))
    out.append("From each port's boot path (" + "; ".join(paths) + "). An option set only under a condition (a "
               "renderer, a dev switch) counts as set. `{x}` is computed at run time.")
    for p in PORTS:
        if launches.get(p) is not None:
            out.append(f"✓ marks a value the {NAMES[p]} launch log ({launches[p]['path']}) passed.")
        else:
            out.append(f"No {NAMES[p]} launch log given, so nothing is checked against a real launch.")
    out.append("")

    def launched(p, key):
        lv = launches.get(p)
        if lv is None:
            return None
        return {v for k, v in lv["keys"] if k == key}

    keys = sorted(set(opts["ios"]) | set(opts["android"]))
    differ, computed, only = [], [], {p: [] for p in PORTS}
    same = []
    for k in keys:
        vi = {v for v, _w in opts["ios"].get(k, [])}
        va = {v for v, _w in opts["android"].get(k, [])}
        if k in opts["ios"] and k in opts["android"]:
            if vi == va:
                same.append(k)
            elif all("{" in v for v in vi | va):
                computed.append(k)  # both computed at run time: the source can't say whether they agree
            else:
                differ.append(k)
        else:
            only["ios" if k in opts["ios"] else "android"].append(k)
    flag = (lambda k: "yes" if k.startswith("-D") and k[2:] in flags else "")
    if differ:
        out += ["### Both set it, to different values", ""]
        out += md_table(["Option", "iOS", "Android", "Contract flag"],
                        [(f"`{k}`", show_values(opts["ios"][k], launched("ios", k)),
                          show_values(opts["android"][k], launched("android", k)), flag(k)) for k in differ])
        out.append("")
    if computed:
        out += ["### Both compute it at run time", "", "The source can't tell whether these agree; a launch log on "
                "each side can.", ""]
        out += md_table(["Option", "iOS", "Android", "Contract flag"],
                        [(f"`{k}`", show_values(opts["ios"][k], launched("ios", k)),
                          show_values(opts["android"][k], launched("android", k)), flag(k)) for k in computed])
        out.append("")
    for p in PORTS:
        if only[p]:
            out += [f"### Only {NAMES[p]} sets it", ""]
            out += md_table(["Option", "Value", "Contract flag"],
                            [(f"`{k}`", show_values(opts[p][k], launched(p, k)), flag(k)) for k in only[p]])
            out.append("")
    if same:
        out += ["### Same on both", "", ", ".join(f"`{k}`" for k in same), ""]
    unset = sorted(f for f in flags if "-D" + f not in opts["ios"] and "-D" + f not in opts["android"])
    if unset:
        out += ["### Contract flags neither boot path sets", "",
                "The bridge Java reads these; they default off or are set by a dev tool, not by either app.", "",
                ", ".join(f"`{f}`" for f in unset), ""]
    for p in PORTS:
        if elsewhere[p]:
            by_fn = {}
            for opt, w, fn in elsewhere[p]:
                by_fn.setdefault(f"{w.split(':')[0]} {fn}", []).append(opt)
            out += [f"### {NAMES[p]} options outside the boot path (not compared)", ""]
            out += [f"- `{where}`: {len(v)} option(s), e.g. `{v[0]}`" for where, v in sorted(by_fn.items())]
            out.append("")
    for p in PORTS:
        if compared[p]:
            out += [f"{NAMES[p]} code also tests for {len(compared[p])} option string(s) it doesn't pass "
                    f"({', '.join(compared[p][:6])}{', ...' if len(compared[p]) > 6 else ''}); they are left out.", ""]
    return out, {"differ": len(differ), "computed": len(computed), "iosOnly": len(only["ios"]), "androidOnly": len(only["android"]),
                 "same": len(same)}


def report_bindings(binds, skipped, methods):
    out = ["## 3. Bridge bindings", ""]
    out.append(f"The Java members each port's native code looks up through JNI (iOS: the census's "
               f"`extract-lookups.py`; Android: `{ANDROID_CPP}` as CMake builds it), matched to the contract's "
               f"{len(methods)} public-static bridge methods (`{rel(CONTRACT)}`). Calls into native code that Java "
               "makes (`RegisterNatives`) aren't covered.")
    out.append("")
    classes = {c for c, _n, _p in methods}
    bound, outside, other = {p: set() for p in PORTS}, {p: [] for p in PORTS}, {p: {} for p in PORTS}
    for p in PORTS:
        for (kind, cls, name, sig), wheres in binds[p].items():
            pkg, simple = split_class(cls)
            bridge = pkg in BRIDGE_PACKAGES and simple in classes
            if bridge and kind == "smethod" and (simple, name, java_params(sig)) in methods:
                bound[p].add((simple, name, java_params(sig)))
            elif kind == "class" and (bridge or pkg == "net/runelite/client/headless"):
                if not bridge:  # a bridge class the contract doesn't cover at all
                    outside[p].append((kind, simple, wheres[0]))
            elif pkg == "net/runelite/client/headless" or bridge:
                outside[p].append((kind, f"{simple}.{name} {sig}", wheres[0]))
            else:
                other[p][(kind, cls, name, sig)] = wheres[0]
    rows = []
    both = bound["ios"] & bound["android"]
    for c in sorted(classes):
        mine = {m for m in methods if m[0] == c}
        rows.append((f"`{c}`", len(mine), len(mine & both), len((mine & bound["ios"]) - both),
                     len((mine & bound["android"]) - both), len(mine - bound["ios"] - bound["android"])))
    total = (len(methods), len(both), len(bound["ios"] - both), len(bound["android"] - both),
             len(methods - bound["ios"] - bound["android"]))
    out += md_table(["Class", "Contract", "Both", "iOS only", "Android only", "Neither"], rows + [("**all**",) + total])
    out.append("")
    for p, q in (("ios", "android"), ("android", "ios")):
        mine = sorted(bound[p] - bound[q])
        if mine:
            out += [f"### Bound by {NAMES[p]} only", ""]
            by = {}
            for c, n, prm in mine:
                by.setdefault(c, []).append(f"{n}({prm})")
            out += [f"- `{c}`: " + ", ".join(f"`{m}`" for m in ms) for c, ms in sorted(by.items())]
            data = [s for s in skipped[q] if s[1] != "-" and any(n == s[1] for _c, n, _p in mine)]
            if data:
                out += ["", f"{NAMES[q]} looks up {', '.join(sorted({f'`{s[1]}`' for s in data}))} with a class from "
                        f"data ({data[0][0]}: {data[0][3]}), so it may bind one of these."]
            out.append("")
    neither = sorted(methods - bound["ios"] - bound["android"])
    if neither:
        out += ["### Bound by neither", "", "Public statics no host looks up (the Java side calls them, or a dev tool does):", ""]
        by = {}
        for c, n, prm in neither:
            by.setdefault(c, []).append(f"{n}({prm})")
        out += [f"- `{c}`: " + ", ".join(f"`{m}`" for m in ms) for c, ms in sorted(by.items())]
        out.append("")
    if not outside["ios"] and not outside["android"]:
        out += ["Every bridge-class lookup on both ports is a contract method.", ""]
    for p in PORTS:
        if outside[p]:
            out += [f"### {NAMES[p]} bridge lookups outside the contract", "",
                    "Instance or field lookups, or methods that aren't public static. The contract doesn't pin these, "
                    "so a Java change can break them without failing the contract check.", ""]
            out += [f"- {k} `{what}` ({w})" for k, what, w in sorted(set(outside[p]))]
            out.append("")
    for p, q in (("ios", "android"), ("android", "ios")):
        mine = sorted(set(other[p]) - set(other[q]))
        if mine:
            out += [f"### Other JNI lookups only {NAMES[p]} makes", ""]
            out += [f"- {k} `{c}" + (f".{n} {s}" if n != "-" else "") + f"` ({other[p][(k, c, n, s)]})" for k, c, n, s in mine]
            out.append("")
    for p in PORTS:
        if skipped[p]:
            out += [f"{NAMES[p]} lookups not extracted: " + "; ".join(f"{w} ({why})" for w, _n, _s, why in skipped[p]), ""]
    return out, {"both": total[1], "iosOnly": total[2], "androidOnly": total[3], "neither": total[4],
                 "outsideIos": len(set(outside["ios"])), "outsideAndroid": len(set(outside["android"]))}


def build(ios_log=None, android_log=None):
    methods, flags = contract()
    revs, rows = overrides()
    opts, elsewhere, compared, launches = {}, {}, {}, {}
    for p, log in (("ios", ios_log), ("android", android_log)):
        opts[p], elsewhere[p], compared[p] = options_of(p)
        if log:
            keys = [option_key(o) for o in launch_options(log, p)]
            missing = sorted({k for k, _v in keys if k not in opts[p]})
            if missing:
                raise InputError(f"{log}: the launch passed {', '.join(missing)}, which the source scan of the {NAMES[p]} "
                                 "boot path didn't find; fix BOOT_PATH or the scan before trusting the report")
            launches[p] = {"path": log, "keys": keys}
    binds, skipped = {}, {}
    for p in PORTS:
        binds[p], skipped[p] = lookups(p)
    head = ["# Port drift: iOS vs Android", "",
            f"Generated by `tools/port-drift/port-drift.py` from the source at `{git('rev-parse', '--short=10', 'HEAD') or '?'}`"
            + (" (with uncommitted changes)" if git("status", "--porcelain", "--untracked-files=no") else "") + ". "
            "It lists differences; whether each is deliberate is for the reader to decide.", ""]
    s1, c1 = report_overrides(revs, rows)
    s2, c2 = report_options(opts, elsewhere, compared, launches, flags)
    s3, c3 = report_bindings(binds, skipped, methods)
    summary = (f"PORT_DRIFT overrides: {c1['oneOnly']} one-port, {c1['bothDiffer']}/{c1['both']} both-but-different; "
               f"options: {c2['differ']} differ, {c2['iosOnly']} iOS-only, {c2['androidOnly']} Android-only; "
               f"bridge: {c3['iosOnly']} iOS-only, {c3['androidOnly']} Android-only, {c3['neither']} neither "
               f"of {len(methods)}")
    return "\n".join(head + s1 + s2 + s3) + "\n", summary


def main(argv=None):
    ap = argparse.ArgumentParser(description="Report where the iOS and Android ports differ, from their source.")
    ap.add_argument("--out", help="write the Markdown report here instead of stdout")
    ap.add_argument("--ios-log", help="hello-shell.log of one iOS launch, to check the options against")
    ap.add_argument("--android-log", help="logcat of one Android boot (jvm-boot tag), to check the options against")
    a = ap.parse_args(argv)
    try:
        text, summary = build(a.ios_log, a.android_log)
    except (InputError, OSError) as e:
        print(f"!! {e}", file=sys.stderr)
        return 2
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(text)
        print(f"report={a.out}")
    else:
        sys.stdout.write(text)
    print(summary, file=sys.stderr if not a.out else sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
