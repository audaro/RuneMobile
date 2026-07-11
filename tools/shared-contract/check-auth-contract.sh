#!/usr/bin/env bash
# Drift guard for the Jagex OAuth wire contract (OAUTH-1).
#
# The three login implementations (iOS JagexLoginViewController.m, Android JagexLogin.kt, and
# ios/dev-tools/fetch-shield-tokens.sh) each re-mint tokens.json in their own runtime BEFORE the JVM
# boots, so the HTTP legs cannot be hoisted into one shared bridge. Instead auth-contract.json is the
# single source of truth for the wire constants, and this checks that every port listed in a pin
# ports entry still carries that exact value — catching one port silently drifting from the others.
#
#   check-auth-contract.sh          # verify; exit 0 clean, 2 on drift
#
# The JSON parse + whitespace-collapsed substring search live in check-auth-contract.py (a separate
# file, matching extract-contract.py: macOS bash 3.2 mis-parses a heredoc inside a command sub).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/check-auth-contract.py"
