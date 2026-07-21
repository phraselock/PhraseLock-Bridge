#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Own copy of the PKI scripts, independent of the PLPServer installer —
# persisted outside the ephemeral staging directory for the same reason as
# there: /tmp can be cleared on reboot, which would break any symlink still
# pointing back into it.
PKI_DIR=/opt/phraselock/pki-scripts-proxy
if [[ ! -d "$PKI_DIR" ]]; then
  mkdir -p /opt/phraselock
  cp -r "$SCRIPT_DIR/pki-scripts" "$PKI_DIR"
fi

PKI_SERVER_DIR="$PKI_DIR/server"
PKI_CONF="$PKI_SERVER_DIR/pki.conf.txt"

DIALOG=$(command -v whiptail || command -v dialog)

# README.txt (how to issue client certificates) goes to its permanent home
# right away, before anything below can fail — /tmp (where this installer
# was extracted) is only a staging area, /etc/frp is where this server's
# setup actually lives afterward.
mkdir -p /etc/frp
cp "$SCRIPT_DIR/README.txt" /etc/frp/README.txt

# Single-tenant setup: fixed ports for the one customer this proxy serves,
# not a dynamically managed pool. Anyone needing multiple tenants on one
# proxy has to design that themselves — out of scope here on purpose.
FRP_HTTPS_PORT=30000
FRP_MQTT_PORT=60000

CURRENT_DNAME=$(grep "^[[:space:]]*dname[[:space:]]*=" "$PKI_CONF" | head -n1 | cut -d'=' -f2- | xargs)
PLACEHOLDER="[Enter a valid domain or IP address]"

while :; do
  # "if ! VAR=$(...)" instead of a bare assignment — whiptail returns
  # nonzero on Cancel/Esc, and a bare assignment under "set -e" would abort
  # the whole script right there with no message at all.
  if ! DNAME=$("$DIALOG" --title "PLP Proxy Server Setup" \
    --inputbox "Public IP address or hostname of this proxy server:" 10 60 \
    "$CURRENT_DNAME" \
    3>&1 1>&2 2>&3); then
    echo "Aborted (Cancel/Esc)." >&2
    exit 1
  fi
  if [[ -z "$DNAME" || "$DNAME" == "$PLACEHOLDER" ]]; then
    "$DIALOG" --title "PLP Proxy Server Setup" --msgbox \
      "Please enter an actual domain name or IP address, not the placeholder." 8 60
    continue
  fi
  break
done

sed -i.bak "s|^\([[:space:]]*dname[[:space:]]*=\).*|\1 ${DNAME}|" "$PKI_CONF"
rm -f "${PKI_CONF}.bak"

CA_PEM="$PKI_SERVER_DIR/CA/ca.${DNAME}.pem"
CERTS_IN_DIR="$SCRIPT_DIR/certs-in"
IMPORT_CA_KEY="$CERTS_IN_DIR/ca.key"
IMPORT_CA_PEM="$CERTS_IN_DIR/ca.pem"

if [[ -f "$CA_PEM" ]]; then
  CA_STATUS="CA already existed for '${DNAME}' — reused, not regenerated."
elif [[ -f "$IMPORT_CA_KEY" && -f "$IMPORT_CA_PEM" ]]; then
  # Migrating this proxy to new hardware: importing the old CA keeps
  # already-issued client certificates valid, instead of orphaning them.
  if "$DIALOG" --title "PLP Proxy Server Setup" --yesno \
"Found an existing CA in certs-in/ (ca.key / ca.pem).

Import it instead of generating a new one? Choose Yes if you're migrating this proxy to new hardware and want already-issued client certificates to remain valid. Choose No to generate a fresh CA instead — existing client certificates would then need to be reissued." 14 74; then
    mkdir -p "$PKI_SERVER_DIR/CA"
    cp "$IMPORT_CA_KEY" "$PKI_SERVER_DIR/CA/ca.${DNAME}.key"
    cp "$IMPORT_CA_PEM" "$PKI_SERVER_DIR/CA/ca.${DNAME}.pem"
    chmod 600 "$PKI_SERVER_DIR/CA/ca.${DNAME}.key"
    if [[ -f "$CERTS_IN_DIR/ca.pkcs8.key" ]]; then
      cp "$CERTS_IN_DIR/ca.pkcs8.key" "$PKI_SERVER_DIR/CA/ca.${DNAME}.pkcs8.key"
    else
      openssl pkcs8 -topk8 -nocrypt -in "$PKI_SERVER_DIR/CA/ca.${DNAME}.key" \
        -out "$PKI_SERVER_DIR/CA/ca.${DNAME}.pkcs8.key"
    fi
    CA_STATUS="CA imported from certs-in/ for '${DNAME}'."
  else
    ( cd "$PKI_SERVER_DIR" && ./make_ca.sh )
    CA_STATUS="CA newly created for '${DNAME}' (import declined)."
  fi
else
  ( cd "$PKI_SERVER_DIR" && ./make_ca.sh )
  CA_STATUS="CA newly created for '${DNAME}'."
fi

( cd "$PKI_SERVER_DIR" && ./make_server.sh )

# --- frps binary -------------------------------------------------------

FRPS_VERSION=0.70.0

case "$(uname -m)" in
  x86_64)  FRP_ARCH=amd64 ;;
  aarch64) FRP_ARCH=arm64 ;;
  *) echo "Error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [[ -x /usr/local/bin/frps ]]; then
  FRPS_STATUS="frps binary already present — left unchanged."
else
  FRP_TMP_DIR=$(mktemp -d)
  FRP_TARBALL="frp_${FRPS_VERSION}_linux_${FRP_ARCH}.tar.gz"
  wget -q -O "$FRP_TMP_DIR/$FRP_TARBALL" \
    "https://github.com/fatedier/frp/releases/download/v${FRPS_VERSION}/${FRP_TARBALL}"
  tar -xzf "$FRP_TMP_DIR/$FRP_TARBALL" -C "$FRP_TMP_DIR"
  install -m 755 "$FRP_TMP_DIR/frp_${FRPS_VERSION}_linux_${FRP_ARCH}/frps" /usr/local/bin/frps
  rm -rf "$FRP_TMP_DIR"
  FRPS_STATUS="frps ${FRPS_VERSION} downloaded and installed."
fi

# --- certs ---------------------------------------------------------------

# Own copy under /etc/frp/certs, rather than pointing at PLPServer's nginx
# certs — frps runs as the generic "nobody" user, which has no dedicated
# group to grant narrower access to, so this copy's key is world-readable
# (matches the reference deployment; PLPServer's own key stays group-
# restricted since that one has a real dedicated group to use).
FRP_CERTS_DIR=/etc/frp/certs
mkdir -p "$FRP_CERTS_DIR"

cp "$PKI_SERVER_DIR/CA/ca.${DNAME}.pem" "$FRP_CERTS_DIR/"
cp "$PKI_SERVER_DIR/server/${DNAME}.crt" "$PKI_SERVER_DIR/server/${DNAME}.key" "$FRP_CERTS_DIR/"
chmod 644 "$FRP_CERTS_DIR/${DNAME}.key"

ln -sf "${DNAME}.crt"    "$FRP_CERTS_DIR/server.crt"
ln -sf "${DNAME}.key"    "$FRP_CERTS_DIR/server.key"
ln -sf "ca.${DNAME}.pem" "$FRP_CERTS_DIR/ca.crt"

# --- frps.toml / auth token ------------------------------------------------

# Reuse an already-deployed token rather than generating a new one on every
# run — frpc clients out in the field are configured against this exact
# value, so it must not silently change on a repeated install.
if [[ -f /etc/frp/frps.toml ]]; then
  EXISTING_TOKEN=$(grep '^auth\.token' /etc/frp/frps.toml | head -n1 | sed -E 's/^auth\.token[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
else
  EXISTING_TOKEN=""
fi

if [[ -n "$EXISTING_TOKEN" ]]; then
  AUTH_TOKEN="$EXISTING_TOKEN"
  TOKEN_STATUS="auth.token already existed — reused."
else
  AUTH_TOKEN=$(openssl rand -hex 64)
  TOKEN_STATUS="auth.token newly generated."
fi

mkdir -p /etc/frp
sed -e "s|__AUTH_TOKEN__|${AUTH_TOKEN}|" \
    -e "s|__HTTPS_PORT__|${FRP_HTTPS_PORT}|" \
    -e "s|__MQTT_PORT__|${FRP_MQTT_PORT}|" \
    "$SCRIPT_DIR/etc/frp/frps.toml" > /etc/frp/frps.toml

# Real file lives under /etc/frp, same convention as mosquitto's
# mosquitto_8883.conf — everything frp-related stays bundled in one place,
# systemd's fixed search path just gets a symlink into it.
cp "$SCRIPT_DIR/etc/frp/frps.service" /etc/frp/frps.service
ln -sf /etc/frp/frps.service /etc/systemd/system/frps.service

# frps runs as "nobody", which has no write access to /var/log itself —
# creating a brand-new file there would fail. Pre-creating it with the
# right ownership sidesteps that; writing to an already-existing file only
# needs permission on the file, not the directory.
touch /var/log/frps.log
chown nobody:nogroup /var/log/frps.log

systemctl daemon-reload
systemctl enable frps >/dev/null 2>&1 || true
systemctl restart frps

# --- nginx (plain TCP forward, no TLS termination here) --------------------

DEBIAN_FRONTEND=noninteractive apt-get update
# libnginx-mod-stream: plain "nginx" doesn't pull this in on Debian, but the
# stream{} directive below needs it — without it nginx.conf fails to parse.
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx libnginx-mod-stream

sed -e "s|__HTTPS_PORT__|${FRP_HTTPS_PORT}|" \
    -e "s|__MQTT_PORT__|${FRP_MQTT_PORT}|" \
    "$SCRIPT_DIR/etc/nginx/nginx.conf" > /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

NGINX_STATUS="nginx installed, forwarding 443→127.0.0.1:${FRP_HTTPS_PORT} and 8883→127.0.0.1:${FRP_MQTT_PORT}."

# --- client certificate ----------------------------------------------------

# Single-tenant: there is exactly one client this proxy will ever serve, so
# its certificate is issued right here instead of requiring a separate
# manual step afterward.
if ! CLIENT_NAME=$("$DIALOG" --title "PLP Proxy Server Setup" --inputbox \
  "Name for the client this proxy serves (used as certificate identifier, e.g. a hostname):" 10 70 \
  "client" 3>&1 1>&2 2>&3); then
  echo "Aborted (Cancel/Esc)." >&2
  exit 1
fi

CLIENT_OUT_DIR="$PKI_SERVER_DIR/${CLIENT_NAME}.FRP"
if [[ -d "$CLIENT_OUT_DIR" ]]; then
  CLIENT_CERT_STATUS="Client certificate for '${CLIENT_NAME}' already existed — left unchanged."
else
  ( cd "$PKI_SERVER_DIR" && ./make_client_frp.sh "$CLIENT_NAME" )
  CLIENT_CERT_STATUS="Client certificate for '${CLIENT_NAME}' created."
fi

# Overwrite the generic README/credentials copied earlier with ones resolved
# to this server's actual values. Kept as two separate files on purpose —
# README.txt is documentation and safe to show/share, credentials.txt holds
# the actual secret (the token) and stays root-only.
sed -e "s|__CLIENT_OUT_DIR__|${CLIENT_OUT_DIR}|g" \
    -e "s|__CLIENT_NAME__|${CLIENT_NAME}|g" \
    -e "s|__PKI_SERVER_DIR__|${PKI_SERVER_DIR}|g" \
    -e "s|__DNAME__|${DNAME}|g" \
    -e "s|__SSH_USER__|$(whoami)|g" \
    "$SCRIPT_DIR/README.txt" > /etc/frp/README.txt

sed "s|__AUTH_TOKEN__|${AUTH_TOKEN}|g" \
    "$SCRIPT_DIR/credentials.txt" > /etc/frp/credentials.txt
chmod 600 /etc/frp/credentials.txt

# Summary as a confirm-with-OK dialog instead of scrolling terminal output,
# which is easy to miss once whiptail redraws the screen. The three files
# below are exactly what needs to be copied to the client's certs-in/
# folder — see README.txt for the transport step, credentials.txt for the
# token.
"$DIALOG" --title "PLP Proxy Server Setup" --msgbox \
"${CA_STATUS}
Server certificate (re)generated for '${DNAME}'.

${FRPS_STATUS}
${TOKEN_STATUS}

frps installed and restarted, listening on port 7000.

${NGINX_STATUS}

${CLIENT_CERT_STATUS}
From the client device, run:
  scp $(whoami)@${DNAME}:${CLIENT_OUT_DIR}/${CLIENT_NAME}.crt certs-in/
  scp $(whoami)@${DNAME}:${CLIENT_OUT_DIR}/${CLIENT_NAME}.key certs-in/
  scp $(whoami)@${DNAME}:${PKI_SERVER_DIR}/CA/ca.${DNAME}.pem certs-in/

See /etc/frp/README.txt for details and /etc/frp/credentials.txt for the
auth.token." 32 90
