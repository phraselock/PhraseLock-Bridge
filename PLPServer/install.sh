#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Persist the PKI scripts — and everything they generate, including CA
# private keys — outside the ephemeral staging directory install.sh was
# extracted into. /tmp can be cleared on reboot, which would silently break
# any symlink still pointing back into it. Copied once; an existing copy
# (and its already-generated CA) is left untouched on a repeated install run.
PKI_DIR=/opt/phraselock/pki-scripts
if [[ ! -d "$PKI_DIR" ]]; then
  mkdir -p /opt/phraselock
  cp -r "$SCRIPT_DIR/pki-scripts" "$PKI_DIR"
fi

PKI_SERVER_DIR="$PKI_DIR/server"
PKI_CONF="$PKI_SERVER_DIR/pki.conf.txt"

# The tool is called "whiptail" on the target system, "dialog" on macOS for
# local testing. Both understand the same options, so a single fallback works.
DIALOG=$(command -v whiptail || command -v dialog)

# README.txt goes to its permanent home right away, before anything below
# can fail — /tmp (where this installer was extracted) is only a staging
# area. Overwritten at the end with real values once they're known.
mkdir -p /opt/phraselock
cp "$SCRIPT_DIR/README.txt" /opt/phraselock/README.txt

# Read the current dname value from pki.conf.txt as the default — the same
# file is where the answer gets persisted below, so a repeated run offers it
# again automatically.
CURRENT_DNAME=$(grep "^[[:space:]]*dname[[:space:]]*=" "$PKI_CONF" | head -n1 | cut -d'=' -f2- | xargs)

# On a fresh install, pki.conf.txt ships with this bracketed placeholder
# instead of a real value — reject it (and an empty answer) so a customer
# who just clicks OK doesn't end up with a certificate issued for the
# placeholder text.
PLACEHOLDER="[Enter a valid domain or IP address]"

# whiptail/dialog write the user's input to stderr (fd 2), not stdout — the
# "3>&1 1>&2 2>&3" trick briefly swaps the file descriptors so that $(...)
# can capture the input.
while :; do
  if ! DNAME=$("$DIALOG" --title "PLP Server Setup" \
    --inputbox "Public IP address or hostname of this server:" 10 60 \
    "$CURRENT_DNAME" \
    3>&1 1>&2 2>&3); then
    echo "Aborted (Cancel/Esc)." >&2
    exit 1
  fi
  if [[ -z "$DNAME" || "$DNAME" == "$PLACEHOLDER" ]]; then
    "$DIALOG" --title "PLP Server Setup" --msgbox \
      "Please enter an actual domain name or IP address, not the placeholder." 8 60
    continue
  fi
  break
done

# Write the answer back into pki.conf.txt so a repeated run of install.sh
# proposes the same value as the default again.
sed -i.bak "s|^\([[:space:]]*dname[[:space:]]*=\).*|\1 ${DNAME}|" "$PKI_CONF"
rm -f "${PKI_CONF}.bak"

CA_PEM="$PKI_SERVER_DIR/CA/ca.${DNAME}.pem"
if [[ -f "$CA_PEM" ]]; then
  CA_STATUS="CA already existed for '${DNAME}' — reused, not regenerated."
else
  ( cd "$PKI_SERVER_DIR" && ./make_ca.sh )
  CA_STATUS="CA newly created for '${DNAME}'."
fi

( cd "$PKI_SERVER_DIR" && ./make_server.sh )

# MQTT client CA (mosquitto's trust anchor for dynamically issued client
# certificates). The port is a fixed application constant, not a per-customer
# value, so it isn't asked for here — anyone needing a different port edits
# pki-scripts/mqtt/pki.conf.txt directly.
PKI_MQTT_DIR="$PKI_DIR/mqtt"
MQTT_PORT=8883
MQTT_DNAME="mqtt_${MQTT_PORT}"
MQTT_CA_PEM="$PKI_MQTT_DIR/CA/ca.${MQTT_DNAME}.pem"

if [[ -f "$MQTT_CA_PEM" ]]; then
  MQTT_CA_STATUS="MQTT CA already existed for '${MQTT_DNAME}' — reused, not regenerated."
else
  ( cd "$PKI_MQTT_DIR" && ./make_ca.sh "$MQTT_PORT" )
  MQTT_CA_STATUS="MQTT CA newly created for '${MQTT_DNAME}'."
fi

# --- client certificate (bootstrap .p12 for API access) --------------------

CLIENT_P12_DIR="$PKI_SERVER_DIR/${DNAME}"
CLIENT_P12_PATH="${CLIENT_P12_DIR}/${DNAME}.p12"

if [[ -f "$CLIENT_P12_PATH" ]]; then
  CLIENT_CERT_STATUS="Client certificate already existed for '${DNAME}' — left unchanged."
  P12_PASSWORD_NOTE="unchanged from when it was first issued — not re-displayed here"
else
  # Confirmed twice, same reasoning as the MQTT password below — a typo
  # here would silently lock the .p12 behind a password nobody knows.
  while :; do
    if ! P12_PASS=$("$DIALOG" --title "PLP Server Setup" --passwordbox \
      "Password to protect the client certificate (.p12) for API access:" 10 70 3>&1 1>&2 2>&3); then
      echo "Aborted (Cancel/Esc)." >&2
      exit 1
    fi
    if ! P12_PASS_CONFIRM=$("$DIALOG" --title "PLP Server Setup" --passwordbox \
      "Confirm password:" 10 60 3>&1 1>&2 2>&3); then
      echo "Aborted (Cancel/Esc)." >&2
      exit 1
    fi
    if [[ -z "$P12_PASS" ]]; then
      "$DIALOG" --title "PLP Server Setup" --msgbox "Password must not be empty." 8 60
      continue
    fi
    if [[ "$P12_PASS" != "$P12_PASS_CONFIRM" ]]; then
      "$DIALOG" --title "PLP Server Setup" --msgbox "Passwords did not match — please try again." 8 60
      continue
    fi
    break
  done

  ( cd "$PKI_SERVER_DIR" && ./make_client.sh "$P12_PASS" )
  CLIENT_CERT_STATUS="Client certificate created for '${DNAME}'."
  P12_PASSWORD_NOTE="$P12_PASS"
fi

# --- nginx -------------------------------------------------------------

# Always run, never gated behind a "command -v nginx" check: apt-get install
# is idempotent on an already-healthy package, and — unlike a presence
# check — it also repairs a half-configured package left over from a prior
# failed install (a real case we hit: a manual "apt purge" plus a failed
# reinstall can leave the nginx binary present but the package broken).
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

# Certs directory is fully replaced on every run, rebuilt from the PKI
# artifacts generated above — never hand-edited, so nothing of value is lost.
NGINX_CERTS_DIR=/etc/nginx/certs
rm -rf "$NGINX_CERTS_DIR"
mkdir -p "$NGINX_CERTS_DIR"

cp "$PKI_SERVER_DIR/CA/ca.${DNAME}.pem" "$NGINX_CERTS_DIR/"
cp "$PKI_SERVER_DIR/server/${DNAME}.crt" "$PKI_SERVER_DIR/server/${DNAME}.key" "$NGINX_CERTS_DIR/"

# Generic aliases so phraselock.conf never has to embed the dname itself.
ln -sf "${DNAME}.crt"    "$NGINX_CERTS_DIR/server.crt"
ln -sf "${DNAME}.key"    "$NGINX_CERTS_DIR/server.key"
ln -sf "ca.${DNAME}.pem" "$NGINX_CERTS_DIR/ca.client.pem"

# Sites this installer doesn't manage: drop the Debian sample entirely, only
# disable (don't delete) the stock default so it stays available as a
# reference but no longer conflicts with silent-drop.conf's default_server.
rm -f /etc/nginx/sites-enabled/test-site /etc/nginx/sites-available/test-site
rm -f /etc/nginx/sites-enabled/default

SITES_SRC_DIR="$SCRIPT_DIR/etc/nginx/sites-available"

sed "s|server_name .*;|server_name ${DNAME};|" \
  "$SITES_SRC_DIR/phraselock.conf" > /etc/nginx/sites-available/phraselock.conf
cp "$SITES_SRC_DIR/silent-drop.conf" /etc/nginx/sites-available/silent-drop.conf

ln -sf /etc/nginx/sites-available/phraselock.conf /etc/nginx/sites-enabled/phraselock.conf
ln -sf /etc/nginx/sites-available/silent-drop.conf  /etc/nginx/sites-enabled/silent-drop.conf

nginx -t
systemctl reload nginx 2>/dev/null || systemctl restart nginx

NGINX_STATUS="nginx installed and reloaded, phraselock.conf serving '${DNAME}'."

# --- mosquitto -----------------------------------------------------------

# Always run, same reasoning as the nginx install above.
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y mosquitto

MOSQ_SRC_DIR="$SCRIPT_DIR/etc/mosquitto"

# mosquitto_8883.conf is the real, tenant-named config; mosquitto.conf is
# only a symlink to it. The stock systemd unit always loads the fixed path
# /etc/mosquitto/mosquitto.conf, but naming the actual file after its
# port/tenant keeps multiple tenants distinguishable — the groundwork for a
# second instance on another port later (which would need its own systemd
# unit, since this one always resolves the same fixed path).
cp "$MOSQ_SRC_DIR/mosquitto_8883.conf" /etc/mosquitto/mosquitto_8883.conf
ln -sf mosquitto_8883.conf /etc/mosquitto/mosquitto.conf

mkdir -p /etc/mosquitto/conf_8883.d
cp "$MOSQ_SRC_DIR/conf_8883.d/ssl.conf" /etc/mosquitto/conf_8883.d/ssl.conf

# The mosquitto process now exists as a system user/group, so the server key
# (chmod 600 by make_server.sh, owned by root) can be shared with it via
# group read access instead of making it world-readable.
chgrp mosquitto "$NGINX_CERTS_DIR/${DNAME}.key"
chmod 640 "$NGINX_CERTS_DIR/${DNAME}.key"

# mosquitto's own certs directory only holds generic-name symlinks into
# nginx's certs directory — same server identity, single source of truth.
MOSQ_CERTS_DIR=/etc/mosquitto/certs
mkdir -p "$MOSQ_CERTS_DIR"
ln -sf "$NGINX_CERTS_DIR/ca.${DNAME}.pem" "$MOSQ_CERTS_DIR/bundle.crt"
ln -sf "$NGINX_CERTS_DIR/${DNAME}.crt"    "$MOSQ_CERTS_DIR/cert.crt"
ln -sf "$NGINX_CERTS_DIR/${DNAME}.key"    "$MOSQ_CERTS_DIR/cert.key"
chown -R mosquitto:mosquitto "$MOSQ_CERTS_DIR"

# The MQTT client CA is copied into the canonical certs directory — same
# pattern as the server cert — instead of pointing capath straight at the
# PKI scripts' own output. nginx/certs stays the single distribution point
# for all cert material; pki-scripts is just the factory that produces it.
MQTT_CLIENT_CA_DIR="$NGINX_CERTS_DIR/client_ca/${MQTT_DNAME}"
mkdir -p "$MQTT_CLIENT_CA_DIR"
cp "$MQTT_CA_PEM" "$MQTT_CLIENT_CA_DIR/ca.${MQTT_DNAME}.pem"

# Register that CA in mosquitto's capath trust store, so it accepts client
# certificates dynamically issued against it.
mkdir -p /etc/mosquitto/client-ca.8883.d
cp "$MOSQ_SRC_DIR/add-client-ca.sh" /etc/mosquitto/client-ca.8883.d/add-client-ca.sh
chmod +x /etc/mosquitto/client-ca.8883.d/add-client-ca.sh
( cd /etc/mosquitto/client-ca.8883.d && ./add-client-ca.sh "$MQTT_CLIENT_CA_DIR/ca.${MQTT_DNAME}.pem" )
chown -R mosquitto:mosquitto /etc/mosquitto/client-ca.8883.d

# Broker login for MQTT clients on 8883 — only asked once; an existing
# password file is left untouched on a repeated install run.
if [[ ! -f /etc/mosquitto/.passwd_8883 ]]; then
  if ! MQTT_USER=$("$DIALOG" --title "PLP Server Setup" --inputbox \
    "MQTT username for this broker:" 10 60 "plpbackend" 3>&1 1>&2 2>&3); then
    echo "Aborted (Cancel/Esc)." >&2
    exit 1
  fi

  # Confirmed twice — a typo here would silently lock the broker's actual
  # credential behind a password nobody knows, so this must not proceed
  # without a match.
  while :; do
    if ! MQTT_PASS=$("$DIALOG" --title "PLP Server Setup" --passwordbox \
      "MQTT password for '${MQTT_USER}':" 10 60 3>&1 1>&2 2>&3); then
      echo "Aborted (Cancel/Esc)." >&2
      exit 1
    fi
    if ! MQTT_PASS_CONFIRM=$("$DIALOG" --title "PLP Server Setup" --passwordbox \
      "Confirm MQTT password for '${MQTT_USER}':" 10 60 3>&1 1>&2 2>&3); then
      echo "Aborted (Cancel/Esc)." >&2
      exit 1
    fi
    if [[ -z "$MQTT_PASS" ]]; then
      "$DIALOG" --title "PLP Server Setup" --msgbox "Password must not be empty." 8 60
      continue
    fi
    if [[ "$MQTT_PASS" != "$MQTT_PASS_CONFIRM" ]]; then
      "$DIALOG" --title "PLP Server Setup" --msgbox "Passwords did not match — please try again." 8 60
      continue
    fi
    break
  done

  mosquitto_passwd -b -c /etc/mosquitto/.passwd_8883 "$MQTT_USER" "$MQTT_PASS"
  MQTT_PASSWD_STATUS="MQTT password created for user '${MQTT_USER}'."
  MQTT_PASSWORD_NOTE="$MQTT_PASS"
else
  # Username still needed below (README/credentials.txt) even when the
  # password prompt itself is skipped on a repeated run.
  MQTT_USER=$(cut -d: -f1 /etc/mosquitto/.passwd_8883 | head -n1)
  MQTT_PASSWD_STATUS="MQTT password file already exists — left unchanged."
  MQTT_PASSWORD_NOTE="unchanged from when it was first set — not re-displayed here"
fi

# mosquitto_passwd creates the file as root, mode 600 — mosquitto runs as
# its own unprivileged user and needs to own it to read it. Applied
# unconditionally so it also repairs a file left over from a prior failed run.
chown mosquitto:mosquitto /etc/mosquitto/.passwd_8883
chmod 600 /etc/mosquitto/.passwd_8883

systemctl enable mosquitto >/dev/null 2>&1 || true
systemctl restart mosquitto

MOSQUITTO_STATUS="mosquitto installed and restarted, listening on 8883 for '${DNAME}'."

# --- plp-custom ------------------------------------------------------------

# plp-custom is built with --release 21 (same requirement will apply to
# plp-backend once that's added here) — install a JRE if none is present or
# the one present is too old. A headless JRE is enough; running a jar
# doesn't need the full JDK or any desktop/font libraries.
JAVA_MAJOR=0
if command -v java >/dev/null 2>&1; then
  JAVA_MAJOR=$(java -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')
fi

if [[ "$JAVA_MAJOR" -lt 21 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jre-headless
  JAVA_STATUS="OpenJDK 21 (headless JRE) installed."
else
  JAVA_STATUS="Java ${JAVA_MAJOR} already present — meets the minimum of 21."
fi

id -u phraselock >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin phraselock

CUSTOM_SRC_DIR="$SCRIPT_DIR/opt/phraselock/custom"
CUSTOM_DIR=/opt/phraselock/custom
mkdir -p "$CUSTOM_DIR/certs/CA"

# Versioned jar + generic symlink, so the systemd unit (which always starts
# "plp-custom.jar") doesn't need to change when the version changes.
CUSTOM_JAR=$(basename "$(ls "$CUSTOM_SRC_DIR"/plp-custom-*.jar)")
cp "$CUSTOM_SRC_DIR/$CUSTOM_JAR" "$CUSTOM_DIR/$CUSTOM_JAR"
ln -sf "$CUSTOM_JAR" "$CUSTOM_DIR/plp-custom.jar"

# plp-core JWT bearer token — the one value in application.properties that's
# specific to this customer. The public key (pl.core.jwt.ec.pub.x/y) and
# pl.core.url are pinned in the template and must not change here.
#
# Auto-fetched from plp-core's token API on every run, since these tokens
# are short-lived (a few days) by design. A longer-lived token is only
# issued to customers who contact PhraseLock directly — once one of those
# is in place (detected by its JWT "type" claim not being "temporary"),
# it's left untouched instead of being silently overwritten by a fresh
# short-lived one on a repeat install.
command -v curl >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl; }

base64url_decode() {
  local seg="$1"
  seg="${seg//-/+}"; seg="${seg//_//}"
  case $(( ${#seg} % 4 )) in
    2) seg="${seg}==" ;;
    3) seg="${seg}=" ;;
  esac
  echo "$seg" | base64 -d 2>/dev/null
}

EXISTING_JWT=""
if [[ -f "$CUSTOM_DIR/application.properties" ]]; then
  EXISTING_JWT=$(grep -E '^pl\.core\.jwt=' "$CUSTOM_DIR/application.properties" | cut -d= -f2-)
fi

EXISTING_JWT_TYPE=""
if [[ -n "$EXISTING_JWT" && "$EXISTING_JWT" != "<bearer-token>" ]]; then
  EXISTING_JWT_TYPE=$(base64url_decode "$(echo "$EXISTING_JWT" | cut -d. -f2)" \
    | grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
fi

if [[ -n "$EXISTING_JWT" && "$EXISTING_JWT" != "<bearer-token>" && "$EXISTING_JWT_TYPE" != "temporary" ]]; then
  PL_CORE_JWT="$EXISTING_JWT"
  JWT_STATUS="plp-core bearer token already set (not a temporary one) — left unchanged."
  JWT_NOTE="unchanged from when it was first set — not re-displayed here"
else
  JWT_RESPONSE=$(curl -fsS "https://phraselock.net/api/plp/v1/validate/getjwt") || JWT_RESPONSE=""
  PL_CORE_JWT=$(echo "$JWT_RESPONSE" | grep -o '"jwttoken"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  JWT_DAYS=$(echo "$JWT_RESPONSE" | grep -o '"days"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')

  if [[ -z "$PL_CORE_JWT" ]]; then
    "$DIALOG" --title "PLP Server Setup" --msgbox \
"Could not fetch a bearer token from plp-core
(https://phraselock.net/api/plp/v1/validate/getjwt).
Check this server's internet connection and re-run install.sh." 10 70
    exit 1
  fi
  JWT_STATUS="plp-core bearer token fetched automatically (valid ~${JWT_DAYS:-a few} days — contact PhraseLock for a longer-lived one)."
  JWT_NOTE="$PL_CORE_JWT"
fi

cp "$CUSTOM_SRC_DIR/application.properties" "$CUSTOM_DIR/application.properties"
sed -i "s|^pl\.core\.jwt=.*|pl.core.jwt=${PL_CORE_JWT}|" "$CUSTOM_DIR/application.properties"

# CA private keys plp-custom needs to issue certificates at runtime: the
# server CA's key (bootstrap client certs) and the MQTT CA's key+cert
# (dynamically issued MQTT client certs) — same set as on hmx.
cp "$PKI_SERVER_DIR/CA/ca.${DNAME}.key" "$CUSTOM_DIR/certs/CA/"
cp "$PKI_MQTT_DIR/CA/ca.${MQTT_DNAME}.key" "$PKI_MQTT_DIR/CA/ca.${MQTT_DNAME}.pem" "$CUSTOM_DIR/certs/CA/"

chown -R phraselock:phraselock "$CUSTOM_DIR"
chmod 600 "$CUSTOM_DIR/certs/CA/"*.key

cp "$CUSTOM_SRC_DIR/plp-custom.service" "$CUSTOM_DIR/plp-custom.service"
cp "$CUSTOM_SRC_DIR/plp-custom.service" /etc/systemd/system/plp-custom.service

systemctl daemon-reload
systemctl enable plp-custom >/dev/null 2>&1 || true
systemctl restart plp-custom

CUSTOM_STATUS="plp-custom installed (${CUSTOM_JAR}) and restarted, listening on 127.0.0.1:7070 behind nginx."

# Overwrite the generic README/credentials copied earlier with ones resolved
# to this server's actual values. Kept as two separate files on purpose —
# README.txt is documentation and safe to show/share, credentials.txt holds
# the actual secrets and stays root-only.
sed -e "s|__CLIENT_P12_PATH__|${CLIENT_P12_PATH}|g" \
    -e "s|__MQTT_USER__|${MQTT_USER}|g" \
    -e "s|__DNAME__|${DNAME}|g" \
    -e "s|__SSH_USER__|$(whoami)|g" \
    "$SCRIPT_DIR/README.txt" > /opt/phraselock/README.txt

sed -e "s|__P12_PASSWORD__|${P12_PASSWORD_NOTE}|g" \
    -e "s|__MQTT_USER__|${MQTT_USER}|g" \
    -e "s|__MQTT_PASSWORD__|${MQTT_PASSWORD_NOTE}|g" \
    -e "s|__PL_CORE_JWT__|${JWT_NOTE}|g" \
    "$SCRIPT_DIR/credentials.txt" > /opt/phraselock/credentials.txt
chmod 600 /opt/phraselock/credentials.txt

# Summary as a confirm-with-OK dialog instead of scrolling terminal output,
# which is easy to miss once whiptail redraws the screen.
"$DIALOG" --title "PLP Server Setup" --msgbox \
"${CA_STATUS}
Server certificate (re)generated for '${DNAME}'.

${MQTT_CA_STATUS}

${CLIENT_CERT_STATUS}

${NGINX_STATUS}

${MOSQUITTO_STATUS}
${MQTT_PASSWD_STATUS}

${JAVA_STATUS}
${CUSTOM_STATUS}
${JWT_STATUS}

See /opt/phraselock/README.txt for how to import the client certificate,
and /opt/phraselock/credentials.txt for its password." 28 78
