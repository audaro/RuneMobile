#!/usr/bin/env bash
# Offline #13 fast-filter: validate each assembled ES300 zone shader with glslangValidator. glslang reports MANY
# errors per pass (vs the Apple sim's one), so it surfaces a whole batch of int<->float (#13) sites at once.
#
# Two glslang quirks vs Apple's EAGL driver, handled here:
#  - glslang rejects in/out interface blocks at `300 es` (ES 3.1 feature) though Apple's EAGL accepts them — so we
#    validate a temp copy bumped to `310 es` to suppress that false-positive while keeping int/float strictness.
#  - glslang is the FAST FILTER, not the authority: the Apple sim (ZoneProbe) remains the final Z0 gate.
# Run from gpu-zone/.  Usage: ./glslang-check.sh [name.stage]   (no arg = all)
set -uo pipefail
cd "$(dirname "$0")/assembled" || exit 1
pat="${1:-}"
for f in *.assembled.glsl; do
	[ -n "$pat" ] && [[ "$f" != "$pat"* ]] && continue
	case "$f" in *.vert.*) st=vert;; *.frag.*) st=frag;; *) continue;; esac
	tmp="/tmp/zz-$f"
	sed 's/^#version 300 es/#version 310 es/' "$f" > "$tmp"
	# Match only the #13 int<->float signatures; this precisely excludes glslang's interface-block false-positives
	# (Apple accepts them) and the "missing #endif"/"compilation terminated" cascade lines that follow a fatal error.
	errs=$(glslangValidator -S "$st" "$tmp" 2>&1 | grep -E 'ERROR: [0-9]+:[0-9]+' \
		| grep -iE 'wrong operand types|cannot convert|Incompatible types in init' || true)
	n=$(printf '%s' "$errs" | grep -c . || true)
	printf '=== %s : %s real-ish errors ===\n' "$f" "$n"
	[ -n "$errs" ] && printf '%s\n' "$errs" | sed -E 's/^ERROR: //; s/ \(.*//' | sort -u
done
