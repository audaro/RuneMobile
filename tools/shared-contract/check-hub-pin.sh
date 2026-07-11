#!/usr/bin/env bash
# GAP-B-2 tripwire — force a conscious review of the RuneLite api/hub version pin on upstream drift.
#
# runelite.properties pins runelite.pluginhub.version + runelite.api.base to a version that intentionally
# lags gradle.properties' project.build.version (commit a310e583c8 — a newer minor's api path 404s). That
# divergence is invisible to `git merge upstream/master`, so the stale pin rides forward forever without
# anyone noticing. This check fails when project.build.version has advanced past the last human-reviewed
# value recorded in hub-pin.ack, so the gate can't go green again until someone re-verifies the pin.
#
# Exit: 0 = pin reviewed + consistent, 1 = review needed (or the pin/ack drifted apart).
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
PROPS="$ROOT/runelite-client/src/main/resources/net/runelite/client/runelite.properties"
GRADLE_PROPS="$ROOT/gradle.properties"
ACK="$ROOT/tools/shared-contract/hub-pin.ack"

for f in "$PROPS" "$GRADLE_PROPS" "$ACK"; do
	[ -f "$f" ] || { echo "✋ hub-pin: missing $f" >&2; exit 1; }
done

val() { grep -E "^$1=" "$2" | head -1 | cut -d= -f2- | tr -d ' \r'; }

proj="$(val 'project.build.version' "$GRADLE_PROPS" | sed 's/-SNAPSHOT//')"
hub_pin="$(val 'runelite.pluginhub.version' "$PROPS")"
api_pin="$(val 'runelite.api.base' "$PROPS" | sed -E 's#.*/runelite-##')"
reviewed="$(val 'reviewed_project_version' "$ACK")"
acked_pin="$(val 'pinned_hub_version' "$ACK")"

fail=0
if [ -z "$proj" ] || [ -z "$hub_pin" ] || [ -z "$reviewed" ]; then
	echo "✋ hub-pin: could not parse versions (proj='$proj' hub='$hub_pin' reviewed='$reviewed')" >&2
	exit 1
fi

if [ "$hub_pin" != "$api_pin" ]; then
	echo "✋ hub-pin: pluginhub.version ($hub_pin) != api.base version ($api_pin) in runelite.properties." >&2
	echo "   The two must move together — fix the mismatch." >&2
	fail=1
fi

if [ "$hub_pin" != "$acked_pin" ]; then
	echo "✋ hub-pin: the pin in runelite.properties ($hub_pin) doesn't match hub-pin.ack ($acked_pin)." >&2
	echo "   If you deliberately changed the pin, update pinned_hub_version in tools/shared-contract/hub-pin.ack." >&2
	fail=1
fi

if [ "$proj" != "$reviewed" ]; then
	echo "✋ hub-pin: project.build.version is now $proj but the api/hub pin was last reviewed at $reviewed." >&2
	echo "   RuneLite's api/hub is pinned to $hub_pin (a newer minor historically 404'd — commit a310e583c8)." >&2
	echo "   Verify whether https://api.runelite.net/runelite-$proj and https://repo.runelite.net/plugins/$proj" >&2
	echo "   now resolve for the client's requests. If they do, lift the pin to \${project.version} in" >&2
	echo "   runelite.properties; if they still 404, keep it. Either way, set reviewed_project_version=$proj" >&2
	echo "   in tools/shared-contract/hub-pin.ack to re-arm this tripwire." >&2
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	echo "hub-pin: OK (pin $hub_pin, reviewed at project $reviewed)."
fi
exit "$fail"
