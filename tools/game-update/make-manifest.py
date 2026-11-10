#!/usr/bin/env python3
"""make-manifest.py - build a signed game-update manifest and its jar assets (GAME-UPDATES-PLAN).

  tools/game-update/make-manifest.py --out DIR --revision N --base-url URL \\
      [--ios-shell SHA [--ios-jars DIR]] [--android-shell SHA [--android-jars DIR]] \\
      [--required] [--expires-days 90] [--key PEM] [--hub-pin X.Y.Z] [--runelite V]

Writes DIR/game-update.json, DIR/game-update.json.sig and one DIR/<set id>-<jar> per jar. The apps read these from
--base-url (the published release, or a local test server). Each set is for one port and one shell commit: the
commit the released app was built from (RMSourceCommit on iOS, BuildConfig.SOURCE_COMMIT on Android). The rules the
apps apply are in ios/app/RuneMobile/RMGameUpdate.m and android/.../GameUpdate.kt; keep the three in step.

Defaults read the staged jars of this checkout (ios/app/jvm-resources, android/app/src/main/assets/jvm), the hub pin
from runelite.properties and the RuneLite version from gradle.properties. The signature is made with openssl and
checked against the key's own public half before anything is written as final.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
KIND = "rune-mobile-game-update"
KEY_DEFAULT = Path.home() / ".config/rune-mobile/update-signing.pem"
JAVAP = os.environ.get("JAVAP", "/opt/homebrew/opt/openjdk@21/bin/javap")
FILE_MAX = 64 << 20


def die(msg):
    print(f"make-manifest: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def game_revision(client_jar):
    """The revision the injected client sends in its js5 handshake: the sipush right after the 765 x 503 applet size
    in client.init (getRevision() itself is obfuscated)."""
    out = subprocess.run([JAVAP, "-c", "-p", "-cp", str(client_jar), "client"], capture_output=True, text=True,
                         errors="replace")
    if out.returncode != 0:
        die(f"javap failed on {client_jar}: {out.stderr.strip()[-300:]}")
    pushes = re.findall(r"sipush\s+(\d+)", out.stdout)
    for i in range(len(pushes) - 2):
        if pushes[i] == "765" and pushes[i + 1] == "503":
            rev = int(pushes[i + 2])
            if 200 <= rev <= 2000:
                return rev
    die(f"no 765/503/<revision> sipush run in {client_jar}'s client class")


def prop(path, key):
    for line in Path(path).read_text().splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    die(f"{key} not found in {path}")


def app_pins():
    """The pinned keys of both apps, in order, as SubjectPublicKeyInfo base64."""
    ios_src = (REPO / "ios/app/RuneMobile/RMGameUpdate.m").read_text()
    block = re.search(r"kPins\[\]\s*=\s*\{(.*?)\};", ios_src, re.S)
    ios = ["".join(re.findall(r'"([^"]*)"', e)) for e in block.group(1).split(",") if '"' in e] if block else []
    kt_src = (REPO / "android/app/src/main/java/dev/audaro/runemobile/GameUpdate.kt").read_text()
    block = re.search(r"val PINS\s*=\s*listOf\((.*?)\)", kt_src, re.S)
    android = re.findall(r'"([A-Za-z0-9+/=]+)"', block.group(1)) if block else []
    return ios, android


def check_key_is_pinned(key):
    """Refuse a key the apps would not accept: every phone would quietly ignore the manifest."""
    der = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"], check=True,
                         capture_output=True).stdout
    mine = base64.b64encode(der).decode()
    ios, android = app_pins()
    if len(ios) != 2 or ios != android:
        die(f"the apps' pinned keys disagree or are not two each (iOS {len(ios)}, Android {len(android)}): "
            "fix RMGameUpdate.m kPins / GameUpdate.kt PINS")
    if mine not in ios:
        die(f"{key} is not a key the apps pin: they would refuse this manifest")
    if mine != ios[0]:
        print("make-manifest: signing with the SPARE key (the apps accept it; rotate the current pin next release)",
              file=sys.stderr)


def ios_jars(d):
    d = Path(d)
    names = ["client-shaded.jar", "client-rlhd.jar", "probes.jar"]
    jars = [d / n for n in names]
    for j in jars:
        if not j.is_file():
            die(f"missing {j}")
    return jars, jars[0]


def android_jars(d):
    d = Path(d)
    gpu = sorted(d.glob("client-*-gpu.jar"))
    rlhd = sorted(d.glob("client-*-rlhd.jar"))
    probes = d / "probes.jar"
    if len(gpu) != 1 or len(rlhd) != 1 or not probes.is_file():
        die(f"{d} must hold exactly one client-*-gpu.jar, one client-*-rlhd.jar and probes.jar "
            f"(found {len(gpu)} gpu, {len(rlhd)} rlhd)")
    return [gpu[0], rlhd[0], probes], gpu[0]


def make_set(port, shell, jars, client, rev, args, out):
    if not re.fullmatch(r"[0-9a-f]{40}", shell):
        die(f"--{port}-shell must be a full 40-hex commit, got {shell!r}")
    set_id = f"{port}-{rev}"
    files = []
    for j in jars:
        size = j.stat().st_size
        if not 0 < size <= FILE_MAX:
            die(f"{j} is {size} bytes")
        asset = f"{set_id}-{j.name}"
        shutil.copyfile(j, out / asset)
        files.append({"name": j.name, "url": args.base_url + asset, "size": size, "sha256": sha256(j)})
    s = {
        "port": port,
        "shell": shell,
        "id": set_id,
        "runelite": args.runelite,
        "gameRevision": game_revision(client),
        "required": bool(args.required),
        "files": files,
    }
    if port == "ios":
        s["pluginHubVersion"] = args.hub_pin
    return s


def main():
    ap = argparse.ArgumentParser(description="Build a signed game-update manifest and its jar assets.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--revision", type=int, required=True, help="above the live manifest's, or the apps refuse it")
    ap.add_argument("--base-url", required=True, help="where the assets will be served, ending in /")
    ap.add_argument("--ios-shell")
    ap.add_argument("--ios-jars", default=str(REPO / "ios/app/jvm-resources"))
    ap.add_argument("--android-shell")
    ap.add_argument("--android-jars", default=str(REPO / "android/app/src/main/assets/jvm"))
    ap.add_argument("--required", action="store_true", help="the cover waits for this set (a revision bump)")
    ap.add_argument("--expires-days", type=int, default=90)
    ap.add_argument("--key", default=str(KEY_DEFAULT))
    ap.add_argument("--hub-pin", default=None)
    ap.add_argument("--runelite", default=None)
    args = ap.parse_args()

    if not args.base_url.endswith("/"):
        die("--base-url must end in /")
    if not (args.base_url.startswith("https://") or re.match(r"http://(127\.0\.0\.1|localhost)[:/]", args.base_url)):
        die("--base-url must be https (or http on loopback for a local test)")
    if not 1 <= args.revision <= 2**31 - 1:
        die("--revision out of range")
    if not (args.ios_shell or args.android_shell):
        die("name at least one shell (--ios-shell / --android-shell)")
    key = Path(args.key)
    if not key.is_file():
        die(f"no signing key at {key} (tools/game-update/keygen.sh)")
    check_key_is_pinned(key)
    args.hub_pin = args.hub_pin or prop(REPO / "runelite-client/src/main/resources/net/runelite/client/runelite.properties",
                                        "runelite.pluginhub.version")
    if not re.fullmatch(r"\d{1,4}\.\d{1,4}\.\d{1,4}", args.hub_pin):
        die(f"hub pin {args.hub_pin!r} is not X.Y.Z")
    args.runelite = args.runelite or prop(REPO / "gradle.properties", "project.build.version")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    sets = []
    if args.ios_shell:
        jars, client = ios_jars(args.ios_jars)
        sets.append(make_set("ios", args.ios_shell, jars, client, args.revision, args, out))
    if args.android_shell:
        jars, client = android_jars(args.android_jars)
        sets.append(make_set("android", args.android_shell, jars, client, args.revision, args, out))

    expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=args.expires_days))
    manifest = {
        "schema": 1,
        "kind": KIND,
        "revision": args.revision,
        "expires": expires.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sets": sets,
    }
    body = (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode()
    if len(body) > 256 * 1024:
        die("manifest is over 256 KB")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "m.json").write_bytes(body)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key), "-out", str(tmp / "m.sig"), str(tmp / "m.json")],
                       check=True)
        pub = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout"], check=True, capture_output=True).stdout
        (tmp / "pub.pem").write_bytes(pub)
        v = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(tmp / "pub.pem"), "-signature",
                            str(tmp / "m.sig"), str(tmp / "m.json")], capture_output=True, text=True)
        if v.returncode != 0:
            die(f"the signature does not verify: {v.stdout.strip()} {v.stderr.strip()}")
        shutil.copyfile(tmp / "m.json", out / "game-update.json")
        shutil.copyfile(tmp / "m.sig", out / "game-update.json.sig")

    for s in sets:
        mb = sum(f["size"] for f in s["files"]) / 1048576
        print(f"  {s['id']:12} shell {s['shell'][:12]}  game rev {s['gameRevision']}  RuneLite {s['runelite']}  "
              f"{mb:.1f} MB{'  required' if s['required'] else ''}")
    print(f"make-manifest: wrote revision {args.revision} to {out} (expires {manifest['expires']})")


if __name__ == "__main__":
    main()
