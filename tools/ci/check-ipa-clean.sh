#!/usr/bin/env bash
# check-ipa-clean.sh <file.ipa | directory> — refuse an iOS build that still carries the developer's identity.
#
# A published IPA is ad-hoc sealed: SideStore and AltStore re-sign it on the phone, so it needs no Apple identity,
# and anything identifying left in it is published to everyone who downloads it. A team-signed build leaks in
# two ways:
#   1. embedded.mobileprovision (or an Xcode *.xcent): the developer's name, Apple ID email, team and device UDIDs.
#   2. A team signature left in a Mach-O's signature space. `codesign --force` writes the new, smaller ad-hoc
#      signature into the old one's space and leaves the rest of the old bytes there, so the old certificate (the
#      team ID, and a name that can be the Apple ID email) survives a re-sign. The first 0.7.1 IPA shipped 40 JRE
#      binaries like that. build-release-artifacts.sh now removes each signature before sealing.
# An ad-hoc signature holds no certificate, so certificate text anywhere in the bundle means a leak.
#
# Exit 0 = clean, 1 = leak found (offenders listed on stderr), 2 = usage or unreadable input.
set -euo pipefail

T="${1:-}"
[ -n "$T" ] || { echo "usage: check-ipa-clean.sh <file.ipa | directory>" >&2; exit 2; }
CERT_RE='Apple Worldwide Developer Relations|Apple Development: |Apple Distribution: |iPhone Developer: |iPhone Distribution: '
PROFILE_RE='\.(mobileprovision|xcent)$'

if [ -f "$T" ]; then
	names="$(unzip -Z1 "$T")" || { echo "check-ipa-clean: cannot list $T" >&2; exit 2; }
	profiles="$(grep -E "$PROFILE_RE" <<<"$names" || true)"
	# Count matching lines across every entry. grep -c reads the whole stream (grep -q would stop early, and under
	# pipefail unzip's SIGPIPE would then turn a match into a "no match").
	hits="$(unzip -p "$T" | LC_ALL=C grep -caE "$CERT_RE" || true)"
	offenders=""
	if [ "${hits:-0}" -gt 0 ]; then
		# Name the files: slower, so only on failure.
		offenders="$(while IFS= read -r n; do
			[[ "$n" == */ ]] && continue
			c="$(unzip -p "$T" "$n" 2>/dev/null | LC_ALL=C grep -caE "$CERT_RE" || true)"
			[ "${c:-0}" -gt 0 ] && echo "$n"
		done <<<"$names" || true)"
	fi
elif [ -d "$T" ]; then
	profiles="$(find "$T" -type f | grep -E "$PROFILE_RE" || true)"
	offenders="$(LC_ALL=C grep -rlaE "$CERT_RE" "$T" || true)"
	hits="$(grep -c . <<<"$offenders" || true)"
else
	echo "check-ipa-clean: no such file or directory: $T" >&2
	exit 2
fi

indent() { while IFS= read -r line; do printf '  %s\n' "$line"; done; }

bad=0
if [ -n "$profiles" ]; then
	echo "check-ipa-clean: $T contains a provisioning profile or entitlements record:" >&2
	indent <<<"$profiles" >&2
	bad=1
fi
if [ "${hits:-0}" -gt 0 ]; then
	echo "check-ipa-clean: $T contains a leftover signing certificate (team ID, name or Apple ID email) in:" >&2
	indent <<<"$offenders" | head -20 >&2
	bad=1
fi
[ "$bad" = 0 ] || exit 1
echo "check-ipa-clean: OK ($T)"
