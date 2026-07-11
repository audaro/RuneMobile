#!/usr/bin/env python3
"""Extract the host-facing contract that BOTH the iOS and Android ports depend on.

The two ports embed the same staged jars and call into them by name via JNI/reflection. The coupling surface
is therefore narrow and precise: the public-static API of the `net.runelite.client.headless.*` bridges + the
two boot/activation entry points the native hosts invoke, plus the `-D` gate/property names those classes read.
A change to any of these can break the *other* port even though its own files were untouched.

Output: a sorted, deterministic list of `METHOD <Class>#<name>(<paramTypes>)` and `FLAG <property>` lines.
Param names (and a leading `final`) are stripped so only the real signature matters. Run via check-contract.sh.
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
    'RuneLiteAccountBridge.java',
    'HeadlessLogin.java', 'HeadlessResize.java',
    # ARCH-2: the renderer boot seams — their -D gates (runelite.routecrlhd / runelite.gfxIos) are part of
    # the host-called surface; a rename must force a baseline ack or it silently breaks the other port's
    # 117HD boot.
    'RLHDStarter.java', 'HeadlessSeams.java',
)] + [os.path.join(AWT, f) for f in (
    'DeviceHeadlessBoot.java', 'UnsafePokeActivation.java',
)]

METHOD_RE = re.compile(r'public\s+static\s+[\w.$<>\[\],\s]+?\s+(\w+)\s*\(([^)]*)\)')
FLAG_RE = re.compile(r'(?:getBoolean|getInteger|getLong|getProperty)\(\s*"([^"]+)"')
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


def main():
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
            entries.add('METHOD %s#%s(%s)' % (cls, m.group(1), param_types(m.group(2))))
        for fm in FLAG_RE.finditer(src):
            entries.add('FLAG %s' % fm.group(1))
        for pm in PAYLOAD_RE.finditer(src):
            entries.add('PAYLOAD %s %s' % (cls, pm.group(1)))
        for hm in HELPER_KEY_RE.finditer(src):
            entries.add('PAYLOAD %s %s' % (cls, hm.group(1)))
        dynamic = len(KEY_CLOSE_RE.findall(src)) - len(PAYLOAD_RE.findall(src))
        if dynamic > 0:
            entries.add('PAYLOAD-DYNAMIC %s count=%d' % (cls, dynamic))
    if missing:
        # A renamed/removed contract file is itself a breaking change — surface it loudly.
        for m in missing:
            entries.add('MISSING-FILE %s' % m)
    for line in sorted(entries):
        print(line)


if __name__ == '__main__':
    main()
