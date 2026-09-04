#!/bin/bash
#
# 02-reload-mosquitto.sh - runs after every certbot renewal.
#
# Unlike nginx, the mosquitto process drops root and runs as its own
# unprivileged user, so it cannot read /etc/letsencrypt/live/__DNAME__/
# directly (privkey.pem is root:root 600). Instead we keep a standing copy
# under /etc/mosquitto/certs, group-readable by mosquitto, and refresh it
# here on every renewal.
#
set -e

SRC="/etc/letsencrypt/live/__DNAME__"
DEST="/etc/mosquitto/certs"

cp "$SRC/fullchain.pem" "$DEST/fullchain.pem"
cp "$SRC/privkey.pem"   "$DEST/privkey.pem"
chown root:mosquitto "$DEST/fullchain.pem" "$DEST/privkey.pem"
chmod 644 "$DEST/fullchain.pem"
chmod 640 "$DEST/privkey.pem"

systemctl restart mosquitto
