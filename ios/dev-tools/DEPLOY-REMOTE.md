# Remote deploy — build here, install on a Mac next to the iPhone (over Tailscale)

One command on the dev Mac builds the jars, ships the tree over Tailscale, and has a remote Mac
run `xcodebuild` + `devicectl install` to its locally-attached iPhone. The dev Mac and the
remote Mac + iPhone can be on completely different networks — Tailscale bridges them.

```
dev Mac ──gradle jars──▶ rsync (Tailscale) ──▶ remote Mac ──▶ xcodegen ▶ xcodebuild ▶ devicectl install ──▶ iPhone
                                                                                                    (you: StikDebug attach)
```

**Why split this way:** `xcodebuild`/`devicectl` are macOS-only, so the device steps *must* run on the
remote Mac. The heavy Java compile has no such constraint, so it runs on the dev Mac (usually the faster
box) and the result is rsync'd in — including the gitignored staged jars, embedded JRE, and `tokens.json`
that `git` doesn't carry.

## Why not install straight to the phone (skip the second Mac)?

Tried and proven impossible on iOS 26.5.1 (2026-06-10). Put the iPhone and the dev Mac both on
Tailscale and you *can* reach the phone by its tailnet IP — `tailscale ping` works, the TCP handshake
to lockdownd's port 62078 even completes — **but iOS interface-gates its developer daemons.** lockdownd
answers a lockdown request arriving on the phone's Wi‑Fi/LAN interface and **resets the byte-identical
request arriving over the Tailscale (VPN) interface.** Proven with a raw `QueryType`: LAN IP →
297‑byte plist reply; tailnet IP → `Connection reset by peer`, same device, same port, same bytes. The
RemoteXPC/install services that the iOS 17.4+ tunnel bootstraps all sit behind that same lockdownd gate,
so there is no `devicectl` / `pymobiledevice3` path direct to a remote phone. (Tailscale itself is fine —
it delivers the packets; iOS just refuses to service the tunnel interface. Also note iOS suspends the
Tailscale NetworkExtension in the background, dropping the phone off the tailnet ~1 min after the app is
backgrounded — moot given the gate.)

Consequences:
- The install connection **must originate on the phone's own physical LAN or its loopback.** That's why
  this doc bridges to a *Mac on the phone's LAN* (or any Tailscale subnet router on that LAN), never to
  the phone itself.
- The only no-second-machine escape is an **on-device** installer (SideStore/AltStore), which talks to
  `localhost` lockdownd over loopback — allowed by the gate, which is exactly why SideStore installs from
  any network. TestFlight/ad-hoc are out: distribution signing strips `get-task-allow` → no JIT.

## One-time setup on the REMOTE Mac

1. Xcode + command-line tools; sign into Xcode ▸ Settings ▸ Accounts with your Apple Developer account,
   and set your Team ID in `ios/dev-tools/signing.env` (gitignored). First build self-provisions via `-allowProvisioningUpdates`.
2. `brew install openjdk@21 xcodegen` (only need JDK 21 if you ever use `--remote-jars`).
3. Enable Remote Login (System Settings ▸ General ▸ Sharing ▸ Remote Login) so SSH works, **or**
   `tailscale up --ssh` to use Tailscale SSH (no key management).
4. Pair the iPhone once over USB and **Trust** this Mac. After that `devicectl` installs work wirelessly
   as long as both are on the same LAN. Get the id: `xcrun devicectl list devices`.

## One-time setup on the DEV Mac (here)

```sh
cp ios/dev-tools/deploy-remote.conf.example ios/dev-tools/deploy-remote.conf
# edit it: REMOTE_HOST (tailnet name), REMOTE_USER, REMOTE_REPO, DEV_UUID
```
`deploy-remote.conf` is gitignored (per-machine; holds the device UUID).

## Use

```sh
ios/dev-tools/deploy-remote.sh                # build jars here, sync, remote build+install
ios/dev-tools/deploy-remote.sh --no-jars      # shell-only change: skip the jar rebuild, reuse staged jars
ios/dev-tools/deploy-remote.sh --remote-jars  # build the jars on the remote (self-contained remote)
```

Then on the phone: attach **StikDebug**, launch RuneMobile (the per-launch JIT attach is a phone-side tap
and cannot be automated). GPU mode = two-finger long-press the launch button; one-finger = L1 kill-test;
tap = CPU path.

## Notes / tuning
- First `rsync` is large (the ~166 MB JRE rides along once); subsequent runs are deltas only.
- `--no-jars` is the fast path when you only touched the Objective-C shell / `project.yml`.
- To skip typing your SSH password each run, add the dev Mac's key to the remote:
  `ssh-copy-id $REMOTE_USER@$REMOTE_HOST` (or rely on Tailscale SSH).
- Pull logs back after a run, e.g.:
  `ssh $REMOTE_USER@$REMOTE_HOST "xcrun devicectl device copy from --device <UUID> --domain-type appDataContainer --domain-identifier dev.audaro.runemobile --source Documents/jvm-stdio.log --destination /tmp/jvm-stdio.log"`
- Want it to fire automatically on every commit instead of one command? Add a `post-commit` git hook that
  runs `deploy-remote.sh --no-jars &`. (Left manual by default — auto-on-commit gets noisy.)
