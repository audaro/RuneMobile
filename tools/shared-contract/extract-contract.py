#!/usr/bin/env python3
"""Extract the host-facing contract that BOTH the iOS and Android ports depend on.

The two ports embed jars built from the same bridge source and call into them by name via JNI/reflection. The coupling surface
is therefore narrow and precise: the public-static API of the `net.runelite.client.headless.*` bridges + the
two boot/activation entry points the native hosts invoke, plus the `-D` gate/property names the bridge reads.
A change to any of these can break the *other* port even though its own files were untouched.

Output: a sorted, deterministic list of `METHOD <Class>#<name>(<paramTypes>) -> <returnType>`, `FLAG <property>`,
`PAYLOAD <Class> <key>` and `PAYLOAD-DYNAMIC <Class> count=N` lines (plus `MISSING-FILE` for a vanished source).
Param names (and a leading `final`) are stripped so only the real signature matters; the return type is part of it,
because the JNI descriptor a shell looks a method up by includes it. Run via check-contract.sh; gen-bridge-api.py
renders the same list as docs/dev/bridge-api-reference.md.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
HEADLESS = os.path.join(ROOT, 'runelite-client/src/main/java/net/runelite/client/headless')
AWT = os.path.join(ROOT, 'ios/dev-tools/awtsmoke')

# Explicit file list = the actual host-called surface (excludes dev probes/tests that aren't part of the contract).
FILES = [os.path.join(HEADLESS, f) for f in (
    'JavaBridge.java', 'MobileUiBridge.java', 'MenuPeekBridge.java', 'MobileChromeBridge.java',
    'HudDataBridge.java', 'HudVeneerBridge.java', 'QuestHelperBridge.java', 'WorldSwitcherBridge.java',
    'LootTrackerBridge.java', 'XpTrackerBridge.java', 'GrandExchangeBridge.java', 'TimeTrackingBridge.java',
    'OverlayBridge.java', 'InfoBoxBridge.java', 'ConfigProfileBridge.java',
    'RuneLiteAccountBridge.java', 'DiagnosticsBridge.java',
    'HeadlessLogin.java', 'HeadlessResize.java',
    # ARCH-2: the renderer boot seams — their -D gates (runelite.routecrlhd / runelite.gfxIos) are part of
    # the host-called surface; a rename must force a baseline ack or it silently breaks the other port's
    # 117HD boot.
    'RLHDStarter.java', 'HeadlessSeams.java',
)] + [os.path.join(AWT, f) for f in (
    'DeviceHeadlessBoot.java', 'UnsafePokeActivation.java',
)]

# The -D properties are scanned more widely than the methods: a flag a host passes is part of the contract wherever
# the Java reads it. Every main-source file in the headless package counts (the starters and probes read their own
# gates), plus the files above.
CLIENT = os.path.join(ROOT, 'runelite-client/src/main/java/net/runelite/client')
# Upstream files also read properties the hosts pass. They read many the hosts never touch, so only the named ones are
# pinned: an upstream merge then diffs the contract only when it renames or drops one of these. A host flag read in an
# upstream file not listed here is invisible to the scan; add it in the change that starts passing the flag.
SEAM_FLAGS = {os.path.join(CLIENT, f): flags for f, flags in (
    ('callback/Hooks.java', ('runelite.fpsprobe',)),
    ('plugins/PluginManager.java', ('runelite.forceDisablePlugins', 'runelite.forceEnablePlugins')),
    ('ui/SplashScreen.java', ('runelite.nosplash',)),
    ('RuneLiteProperties.java', ('runelite.pluginhub.version',)),
)}


def flag_files():
    """Our own sources, whose every -D read is part of the contract (SEAM_FLAGS covers the upstream ones)."""
    headless = [os.path.join(HEADLESS, f) for f in os.listdir(HEADLESS) if f.endswith('.java')]
    return sorted(set(headless) | set(FILES))


METHOD_RE = re.compile(r'public\s+static\s+[\w.$<>\[\],\s]+?\s+(\w+)\s*\(([^)]*)\)')
FLAG_RE = re.compile(r'(?:getBoolean|getInteger|getLong|getProperty)\(\s*"([^"]+)"')
# A property read through a named constant (Integer.getInteger(MAX_PROP, 20)) resolves against the constant's
# `static final String MAX_PROP = "..."` in the same file. Only the System-property readers count here: upstream code
# also passes constants to Properties.getProperty, and those name resource keys, not -D options.
FLAG_CONST_RE = re.compile(r'\b(?:System\.getProperty|Boolean\.getBoolean|Integer\.getInteger|Long\.getLong)\(\s*'
                           r'([A-Z][A-Z0-9_]*)\s*[,)]')
STRING_CONST_RE = r'\bstatic\s+final\s+String\s+%s\s*=\s*"([^"]+)"'
# A property name handed to a helper that reads it (parsePoint("runelite.headless.autologin.point", 302, 312)).
# Writes don't count: a property the Java only sets is not one a host can pass.
FLAG_HELPER_RE = re.compile(r'\b(?!setProperty\b|clearProperty\b)[a-z]\w*\(\s*"(runelite\.[A-Za-z0-9_.\-]+)"')
MODIFIERS = {'public', 'static', 'final', 'synchronized', 'native', 'strictfp'}
# ARCH-2: the JSON payload keys the native UIs parse. The bridges hand-roll their JSON, so every emitted key
# appears in source as an escaped-quote literal (\"key\":) — extract those per class so a key rename/removal
# diffs baseline.txt and forces the same acknowledgement as a signature change. Keys assembled from variables
# are invisible to this scan — keep payload key names literal in the builders.
PAYLOAD_RE = re.compile(r'\\"([A-Za-z_][A-Za-z0-9_]*)\\"\s*:')
# Keys routed through an append-style helper (appendRect(c, sb, "window", ...), appendSpriteSlot(sb, "inv",
# slot)) never appear as \"key\": literals — the helper builds that from its String arg. Pin the literal at
# the CALL site instead: an append*-named call whose String arg is followed by more args is a key, not a
# value (sb.append("...") has no trailing comma). If a helper is renamed the entries drop out, which diffs
# the baseline — the gate still fires.
HELPER_KEY_RE = re.compile(r'\bappend[A-Za-z0-9_]*\(\s*(?:[A-Za-z_][\w.]*\s*,\s*)*"([A-Za-z_][A-Za-z0-9_]*)"\s*,')
# Tripwire for everything else: each \"key\": literal contains exactly one escaped-quote-colon, so any
# EXCESS \": in a file is a JSON key assembled from a variable (e.g. sb.append(key).append("\":")). Pin the
# per-class COUNT — a new dynamic-key site changes it and forces the same baseline ack, instead of silently
# shipping an unpinned key.
KEY_CLOSE_RE = re.compile(r'\\"\s*:')


def param_types(params):
    out = []
    for p in params.split(','):
        p = p.strip()
        if not p:
            continue
        if p.startswith('final '):
            p = p[len('final '):]
        toks = p.split()
        t = ' '.join(toks[:-1]) if len(toks) >= 2 else p
        out.append(t.replace(' ', ''))
    return ','.join(out)


def return_type(src, m):
    """The declared return type of the METHOD_RE match m, as written ('void' if the scan finds none)."""
    pre = src[m.start():m.start(1)].split()
    return ' '.join(t for t in pre if t not in MODIFIERS) or 'void'


def flags_read(src):
    """Every -D property name src reads: literal reads, reads through a String constant, and helper calls."""
    found = set(FLAG_RE.findall(src))
    for name in FLAG_CONST_RE.findall(src):
        cm = re.search(STRING_CONST_RE % re.escape(name), src)
        if cm:
            found.add(cm.group(1))
    found.update(FLAG_HELPER_RE.findall(src))
    return found


def collect():
    """Return the sorted contract lines (what main() prints; gen-bridge-api.py renders the same list)."""
    entries = set()
    missing = []
    for path in FILES:
        if not os.path.isfile(path):
            missing.append(os.path.relpath(path, ROOT))
            continue
        cls = os.path.splitext(os.path.basename(path))[0]
        with open(path, encoding='utf-8', errors='replace') as fh:
            src = fh.read()
        for m in METHOD_RE.finditer(src):
            entries.add('METHOD %s#%s(%s) -> %s'
                        % (cls, m.group(1), param_types(m.group(2)), return_type(src, m).replace(' ', '')))
        for pm in PAYLOAD_RE.finditer(src):
            entries.add('PAYLOAD %s %s' % (cls, pm.group(1)))
        for hm in HELPER_KEY_RE.finditer(src):
            entries.add('PAYLOAD %s %s' % (cls, hm.group(1)))
        dynamic = len(KEY_CLOSE_RE.findall(src)) - len(PAYLOAD_RE.findall(src))
        if dynamic > 0:
            entries.add('PAYLOAD-DYNAMIC %s count=%d' % (cls, dynamic))
    for path in flag_files() + sorted(SEAM_FLAGS):
        if not os.path.isfile(path):
            if path not in FILES:
                missing.append(os.path.relpath(path, ROOT))
            continue
        with open(path, encoding='utf-8', errors='replace') as fh:
            read = flags_read(fh.read())
        # A pinned seam flag the file no longer reads drops out of the list, which diffs the baseline.
        for flag in (read & set(SEAM_FLAGS[path])) if path in SEAM_FLAGS else read:
            entries.add('FLAG %s' % flag)
    if missing:
        # A renamed/removed contract file is itself a breaking change — surface it loudly.
        for m in missing:
            entries.add('MISSING-FILE %s' % m)
    return sorted(entries)


def main():
    if sys.argv[1:] == ['--seam-files']:
        # The upstream files the scan reads, for a caller that copies the scanned sources out (the pre-commit hook).
        for path in sorted(SEAM_FLAGS):
            print(os.path.relpath(path, ROOT))
        return
    for line in collect():
        print(line)


if __name__ == '__main__':
    main()
