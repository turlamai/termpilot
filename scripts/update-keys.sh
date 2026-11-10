#!/usr/bin/env bash
# Generate the Ed25519 keypair that signs TermPilot update manifests
# (family pattern: hackdigest/scripts/update-keys.sh — taskly, syncpilot).
#
#   scripts/update-keys.sh [private-key-path]
#
# Default private key location: ~/.termpilot/update-signing-key.pem —
# OUTSIDE the repository. The public key is printed as base64
# (SubjectPublicKeyInfo DER) for embedding in backend/updater.rkt.
#
# One-time: also put the PEM into the GitHub secret
# UPDATE_ED25519_PRIVATE_KEY so release.yml can sign the update manifest.
set -euo pipefail

KEY_PATH="${1:-$HOME/.termpilot/update-signing-key.pem}"

# Ed25519 needs OpenSSL 3+ (macOS ships LibreSSL, which cannot do it).
OPENSSL_BIN="${OPENSSL_BIN:-}"
if [[ -z "$OPENSSL_BIN" ]]; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl \
                   /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" version 2>/dev/null | grep -q "OpenSSL 3"; then
      OPENSSL_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$OPENSSL_BIN" ]] || {
  echo "error: OpenSSL 3.x required for Ed25519 (brew install openssl@3," >&2
  echo "       or set OPENSSL_BIN=/path/to/openssl)" >&2
  exit 1
}

if [[ -f "$KEY_PATH" ]]; then
  echo "Private key already exists: $KEY_PATH" >&2
  echo "Delete it first if you really want to rotate (rotating requires a" >&2
  echo "public-key rollout release)." >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
umask 077
"$OPENSSL_BIN" genpkey -algorithm ed25519 -out "$KEY_PATH"

PUB_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"

echo "Private key: $KEY_PATH  (back this up; put the PEM in the GitHub secret"
echo "             UPDATE_ED25519_PRIVATE_KEY)"
echo "Public key (base64 SPKI DER, embed in backend/updater.rkt):"
echo "  $PUB_B64"
