#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_IN_DIR="$SCRIPT_DIR/certs-in"

DIALOG=$(command -v whiptail || command -v dialog)

# Single-tenant setup, same fixed ports as PLPProxyServer — must match
# exactly, since they're not negotiated, just two hardcoded constants on
# both ends.
FRP_HTTPS_PORT=30000
FRP_MQTT_PORT=60000

# --- inputs ------------------------------------------------------------

CONF_FILE=/etc/frp/frpc.toml
if [[ -f "$CONF_FILE" ]]; then
  CURRENT_SERVER_ADDR=$(grep '^serverAddr' "$CONF_FILE" | head -n1 | sed -E 's/^serverAddr[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
  CURRENT_TOKEN=$(grep '^auth\.token' "$CONF_FILE" | head -n1 | sed -E 's/^auth\.token[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
else
  CURRENT_SERVER_ADDR=""
  CURRENT_TOKEN=""
fi

# "if ! VAR=$(...)" instead of a bare assignment — whiptail returns nonzero
# on Cancel/Esc, and a bare assignment under "set -e" would abort the whole
# script right there with no message at all. This turns that into a clear
# error instead of a silent, confusing exit.
if ! SERVER_ADDR=$("$DIALOG" --title "PLP Proxy Client Setup" --inputbox \
  "Public IP address or hostname of the proxy server (PLPProxyServer):" 10 60 \
  "$CURRENT_SERVER_ADDR" 3>&1 1>&2 2>&3); then
  echo "Aborted (Cancel/Esc)." >&2
  exit 1
fi

if ! AUTH_TOKEN=$("$DIALOG" --title "PLP Proxy Client Setup" --inputbox \
  "auth.token, from the proxy server's install summary:" 12 70 \
  "$CURRENT_TOKEN" 3>&1 1>&2 2>&3); then
  echo "Aborted (Cancel/Esc)." >&2
  exit 1
fi

if [[ -z "$SERVER_ADDR" || -z "$AUTH_TOKEN" ]]; then
  "$DIALOG" --title "PLP Proxy Client Setup" --msgbox \
    "Server address and token must not be empty. Aborting." 8 60
  exit 1
fi

# --- frpc binary -------------------------------------------------------

FRPC_VERSION=0.70.0

case "$(uname -m)" in
  x86_64)  FRP_ARCH=amd64 ;;
  aarch64) FRP_ARCH=arm64 ;;
  *) echo "Error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [[ -x /usr/local/bin/frpc ]]; then
  FRPC_STATUS="frpc binary already present — left unchanged."
else
  FRP_TMP_DIR=$(mktemp -d)
  FRP_TARBALL="frp_${FRPC_VERSION}_linux_${FRP_ARCH}.tar.gz"
  wget -q -O "$FRP_TMP_DIR/$FRP_TARBALL" \
    "https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/${FRP_TARBALL}"
  tar -xzf "$FRP_TMP_DIR/$FRP_TARBALL" -C "$FRP_TMP_DIR"
  install -m 755 "$FRP_TMP_DIR/frp_${FRPC_VERSION}_linux_${FRP_ARCH}/frpc" /usr/local/bin/frpc
  rm -rf "$FRP_TMP_DIR"
  FRPC_STATUS="frpc ${FRPC_VERSION} downloaded and installed."
fi

# --- certs ---------------------------------------------------------------

# README.txt is copied to its permanent home first, before anything can
# fail below — /tmp (where this installer was extracted) is only a staging
# area, but /etc/frp is where this device's setup actually lives afterward,
# so that's where the instructions need to still be found later too.
mkdir -p /etc/frp
cp "$SCRIPT_DIR/README.txt" /etc/frp/README.txt

# Unlike PLPServer/PLPProxyServer, this installer does NOT generate its own
# CA/certs — the client certificate has to be issued by the proxy server's
# own CA (via make_client_frp.sh over there), then copied into certs-in/
# next to this script before running it.
CLIENT_CRT=$(ls "$CERTS_IN_DIR"/*.crt 2>/dev/null | head -n1 || true)
CLIENT_KEY=$(ls "$CERTS_IN_DIR"/*.key 2>/dev/null | head -n1 || true)
CA_CRT=$(ls "$CERTS_IN_DIR"/ca.*.pem 2>/dev/null | head -n1 || true)

if [[ -z "$CLIENT_CRT" || -z "$CLIENT_KEY" || -z "$CA_CRT" ]]; then
  "$DIALOG" --title "PLP Proxy Client Setup" --msgbox \
"Missing certificate files in ${CERTS_IN_DIR}.

Expected: a client .crt and .key, plus the server's ca.<dname>.pem. See /etc/frp/README.txt for exactly what to run on the proxy server and what to copy here." 12 74
  exit 1
fi

FRP_CERTS_DIR=/etc/frp/certs
mkdir -p "$FRP_CERTS_DIR"
cp "$CLIENT_CRT" "$FRP_CERTS_DIR/client.crt"
cp "$CLIENT_KEY" "$FRP_CERTS_DIR/client.key"
cp "$CA_CRT" "$FRP_CERTS_DIR/ca.crt"
chown nobody:nogroup "$FRP_CERTS_DIR/client.key"
chmod 600 "$FRP_CERTS_DIR/client.key"

# --- frpc.toml -------------------------------------------------------------

sed -e "s|__SERVER_ADDR__|${SERVER_ADDR}|" \
    -e "s|__AUTH_TOKEN__|${AUTH_TOKEN}|" \
    -e "s|__HTTPS_PORT__|${FRP_HTTPS_PORT}|" \
    -e "s|__MQTT_PORT__|${FRP_MQTT_PORT}|" \
    "$SCRIPT_DIR/etc/frp/frpc.toml" > /etc/frp/frpc.toml

# Real file lives under /etc/frp, same convention as frps/mosquitto —
# systemd's fixed search path just gets a symlink into it.
cp "$SCRIPT_DIR/etc/frp/frpc.service" /etc/frp/frpc.service
ln -sf /etc/frp/frpc.service /etc/systemd/system/frpc.service

# frpc runs as "nobody", which can't create a brand-new file under
# /var/log itself — pre-create it with the right ownership.
touch /var/log/frpc.log
chown nobody:nogroup /var/log/frpc.log

systemctl daemon-reload
systemctl enable frpc >/dev/null 2>&1 || true
systemctl restart frpc

"$DIALOG" --title "PLP Proxy Client Setup" --msgbox \
"${FRPC_STATUS}

frpc configured for server '${SERVER_ADDR}' and restarted.
Tunnels: local 443 -> remote ${FRP_HTTPS_PORT}, local 8883 -> remote ${FRP_MQTT_PORT}.

See /etc/frp/README.txt for background if anything needs troubleshooting later." 16 78
