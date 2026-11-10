#!/usr/bin/env bash
# keygen.sh - make the game-update signing keys, once per maintainer (GAME-UPDATES-PLAN).
#
#   tools/game-update/keygen.sh        # writes ~/.config/rune-mobile/update-signing{,-spare}.pem, prints the pins
#   tools/game-update/keygen.sh --pins # prints the pins of the existing keys
#
# Two ECDSA P-256 keys: the current one signs every manifest; the spare exists so a lost or leaked current key can be
# replaced by a release signed with the spare. Both public keys are pinned in both apps (SubjectPublicKeyInfo DER,
# base64). The private keys never enter CI or the repo. Move the spare offline once its pin is in a release.
set -euo pipefail
DIR="${RM_KEY_DIR:-$HOME/.config/rune-mobile}"
KEYS=(update-signing update-signing-spare)

pins() {
	for k in "${KEYS[@]}"; do
		[ -f "$DIR/$k.pem" ] || { echo "keygen: $DIR/$k.pem is missing" >&2; exit 1; }
		printf '%-22s %s\n' "$k" "$(openssl pkey -in "$DIR/$k.pem" -pubout -outform DER | base64 | tr -d '\n')"
	done
}

if [ "${1:-}" = "--pins" ]; then pins; exit 0; fi

umask 077
mkdir -p "$DIR"
for k in "${KEYS[@]}"; do
	if [ -e "$DIR/$k.pem" ]; then
		echo "keygen: $DIR/$k.pem already exists; refusing to overwrite it (a new key strands every pinned app)" >&2
		exit 1
	fi
done
for k in "${KEYS[@]}"; do
	openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -out "$DIR/$k.pem"
	chmod 600 "$DIR/$k.pem"
done
echo "keygen: wrote ${KEYS[*]} in $DIR. Public keys to pin (SPKI DER, base64):"
pins
