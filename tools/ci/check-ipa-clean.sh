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
# Exit 0 = clean, 1 = leak found (offenders listed on stderr), 2 = usage error or input that could not be read in
# full. It fails closed: a scan that missed part of its input never reports clean.
set -euo pipefail

T="${1:-}"
[ -n "$T" ] || { echo "usage: check-ipa-clean.sh <file.ipa | directory>" >&2; exit 2; }
CERT_RE='Apple Worldwide Developer Relations|Apple Development: |Apple Distribution: |iPhone Developer: |iPhone Distribution: '
PROFILE_RE='\.(mobileprovision|xcent)$'
fail() { echo "check-ipa-clean: $*" >&2; exit 2; }
indent() { while IFS= read -r line; do printf '  %s\n' "$line"; done; }

if [ -f "$T" ]; then
	names="$(unzip -Z1 "$T")" || fail "cannot list $T"
	rc=0; profiles="$(grep -E "$PROFILE_RE" <<<"$names")" || rc=$?
	[ "$rc" -le 1 ] || fail "grep failed on the entry list of $T"
	# Stream every entry through one grep. The exit statuses are read separately: unzip must succeed (a short read
	# would scan only part of the archive), and grep's 1 just means no match. grep -c reads to the end, so unzip
	# never sees SIGPIPE. The count goes to a file because a $(...) would lose PIPESTATUS.
	tmp="$(mktemp "${TMPDIR:-/tmp}/check-ipa-clean.XXXXXX")" || fail "cannot make a temp file"
	trap 'rm -f "$tmp"' EXIT
	set +e
	unzip -p "$T" | LC_ALL=C grep -caE "$CERT_RE" >"$tmp"
	st=("${PIPESTATUS[@]}")
	set -e
	[ "${st[0]}" -eq 0 ] || fail "could not read every entry of $T (unzip exit ${st[0]})"
	[ "${st[1]}" -le 1 ] || fail "grep failed scanning $T (exit ${st[1]})"
	hits="$(cat "$tmp")"
	offenders=""
	if [ "${hits:-0}" -gt 0 ]; then
		# Name the files, one entry at a time: slower, so only once the verdict is already "leak".
		offenders="$(while IFS= read -r n; do
			[[ "$n" == */ ]] && continue
			c="$(unzip -p "$T" "$n" 2>/dev/null | LC_ALL=C grep -caE "$CERT_RE" || true)"
			[ "${c:-0}" -gt 0 ] && echo "$n"
		done <<<"$names" || true)"
		[ -n "$offenders" ] || offenders="(could not name the files)"
	fi
elif [ -d "$T" ]; then
	files="$(find "$T" -type f)" || fail "cannot list every file under $T"
	rc=0; profiles="$(grep -E "$PROFILE_RE" <<<"$files")" || rc=$?
	[ "$rc" -le 1 ] || fail "grep failed on the file list of $T"
	# grep -r: 0 = matches, 1 = none, 2 = a file it could not read (even with matches), which fails the check.
	rc=0; offenders="$(LC_ALL=C grep -rlaE "$CERT_RE" "$T")" || rc=$?
	[ "$rc" -le 1 ] || fail "could not read every file under $T (grep exit $rc)"
	hits="$(grep -c . <<<"$offenders" || true)"
else
	fail "no such file or directory: $T"
fi

bad=0
if [ -n "$profiles" ]; then
	echo "check-ipa-clean: $T contains a provisioning profile or entitlements record:" >&2
	indent <<<"$profiles" >&2
	bad=1
fi
if [ "${hits:-0}" -gt 0 ]; then
	echo "check-ipa-clean: $T contains a leftover signing certificate (team ID, name or Apple ID email) in:" >&2
	# Trim before printing: a pipe into head could kill the printer with SIGPIPE and turn exit 1 into 141.
	n_off="$(grep -c . <<<"$offenders" || true)"
	indent <<<"$(head -n 20 <<<"$offenders")" >&2
	if [ "${n_off:-0}" -gt 20 ]; then echo "  ... and $((n_off - 20)) more" >&2; fi
	bad=1
fi
[ "$bad" = 0 ] || exit 1
echo "check-ipa-clean: OK ($T)"
