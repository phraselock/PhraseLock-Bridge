#!/bin/bash
#
# add-client-ca.sh – registers a client CA certificate in mosquitto's capath
# trust store (OpenSSL hash-based symlink), so mosquitto accepts client
# certificates signed by that CA on the TLS listener.
#
# Usage: ./add-client-ca.sh <CA certificate file>
#
set -euo pipefail

CAFILE="$1"
CAPATH="./"

if [[ ! -f "$CAFILE" ]]; then
    echo "Error: file '$CAFILE' does not exist."
    exit 1
fi

BASENAME=$(basename "$CAFILE")

# Hash computed from the original file, used as the OpenSSL capath filename.
HASH=$(openssl x509 -hash -noout -in "$CAFILE")

LINK="$CAPATH/$HASH.0"

if [[ -L "$LINK" ]]; then
    echo "Removing old symlink: $LINK"
    rm -f "$LINK"
fi

echo "Creating symlink: $LINK -> $CAFILE"
ln -s "$CAFILE" "$LINK"

echo "Done. CA successfully linked."
