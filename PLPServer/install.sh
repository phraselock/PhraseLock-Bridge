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

# One-time migration: these directories used to be named "server"/"mqtt",
# from when the "server" CA still signed this server's own TLS certificate
# too (pre Let's Encrypt). Renamed to "clients-api"/"clients-mqtt" to make
# clear both are client-cert-only CAs now (see pki-scripts/clients-api/
# pki.conf.txt) — an existing install's already-issued CAs are moved into
# place here instead of silently missing the rename and erroring out below.
[[ -d "$PKI_DIR/server" && ! -d "$PKI_DIR/clients-api"  ]] && mv "$PKI_DIR/server" "$PKI_DIR/clients-api"
[[ -d "$PKI_DIR/mqtt"   && ! -d "$PKI_DIR/clients-mqtt" ]] && mv "$PKI_DIR/mqtt"   "$PKI_DIR/clients-mqtt"

PKI_CLIENTS_API_DIR="$PKI_DIR/clients-api"
PKI_CONF="$PKI_CLIENTS_API_DIR/pki.conf.txt"

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
PLACEHOLDER="[Enter a valid public domain name]"

# Never pre-fill the inputbox with the literal placeholder text — clearing
# pre-filled text in whiptail can be fiddly depending on terminal/keyboard
# setup, and a real case we hit: leftover placeholder fragments (e.g. the
# "[" / "]") got typed together with the real domain, produced a garbage
# DNAME that slipped past the checks below (neither empty, nor an exact
# placeholder match, nor a bare IPv4), and only surfaced as an opaque
# certbot failure much later. Starting empty on a fresh config sidesteps
# the whole problem; a previously-configured real domain is still offered
# as the default on a repeat run, same as before.
DNAME_DEFAULT="$CURRENT_DNAME"
[[ "$DNAME_DEFAULT" == "$PLACEHOLDER" ]] && DNAME_DEFAULT=""

# Let's Encrypt cannot issue a certificate for a bare IP address (only for
# DNS names), so — unlike the old self-signed flow — dname must now be an
# actual domain that already resolves to this server. Rejected with the
# same regex used elsewhere in the PKI scripts to detect IPv4 literals.
IPV4_RE='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

# Basic FQDN shape check (labels of alnum/hyphen, dot-separated, ending in
# a letters-only TLD-like label) — catches garbage input (leftover
# placeholder fragments, stray brackets/spaces from a botched edit, etc.)
# here instead of letting it reach certbot and fail with a confusing error
# far downstream.
FQDN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

# whiptail/dialog write the user's input to stderr (fd 2), not stdout — the
# "3>&1 1>&2 2>&3" trick briefly swaps the file descriptors so that $(...)
# can capture the input.
while :; do
  if ! DNAME=$("$DIALOG" --title "PLP Server Setup" \
    --inputbox "Public domain name (FQDN) of this server.\n\nMust already point here via DNS (A/AAAA record) — Let's Encrypt validates ownership over HTTP on port 80 before issuing the certificate:" 14 70 \
    "$DNAME_DEFAULT" \
    3>&1 1>&2 2>&3); then
    echo "Aborted (Cancel/Esc)." >&2
    exit 1
  fi
  if [[ -z "$DNAME" || "$DNAME" == "$PLACEHOLDER" ]]; then
    "$DIALOG" --title "PLP Server Setup" --msgbox \
      "Please enter an actual domain name, not the placeholder." 8 60
    continue
  fi
  if [[ "$DNAME" =~ $IPV4_RE ]]; then
    "$DIALOG" --title "PLP Server Setup" --msgbox \
      "Let's Encrypt cannot issue a certificate for a bare IP address.\nPlease enter a domain name that resolves to this server instead." 9 70
    continue
  fi
  if ! [[ "$DNAME" =~ $FQDN_RE ]]; then
    "$DIALOG" --title "PLP Server Setup" --msgbox \
      "'${DNAME}' doesn't look like a valid domain name (unexpected characters or format — e.g. leftover [ ] from the placeholder?). Please clear the field completely and re-type the domain." 10 70
    continue
  fi
  break
done

# Write the answer back into pki.conf.txt so a repeated run of install.sh
# proposes the same value as the default again.
sed -i.bak "s|^\([[:space:]]*dname[[:space:]]*=\).*|\1 ${DNAME}|" "$PKI_CONF"
rm -f "${PKI_CONF}.bak"

# --- Let's Encrypt contact e-mail ------------------------------------------
#
# Used only for certbot's expiry/problem notifications, not for the CA/client
# certificate subject — defaults to the PKI's subj_email so most installs
# don't need to type anything here.
CURRENT_LE_EMAIL=$(grep "^[[:space:]]*subj_email[[:space:]]*=" "$PKI_CONF" | head -n1 | cut -d'=' -f2- | xargs)
if ! LE_EMAIL=$("$DIALOG" --title "PLP Server Setup" \
    --inputbox "E-mail address for Let's Encrypt renewal/expiry notices:" 10 65 \
    "$CURRENT_LE_EMAIL" \
    3>&1 1>&2 2>&3); then
  echo "Aborted (Cancel/Esc)." >&2
  exit 1
fi

CA_PEM="$PKI_CLIENTS_API_DIR/CA/ca.${DNAME}.pem"
if [[ -f "$CA_PEM" ]]; then
  CA_STATUS="CA already existed for '${DNAME}' — reused, not regenerated."
else
  ( cd "$PKI_CLIENTS_API_DIR" && ./make_ca.sh )
  CA_STATUS="CA newly created for '${DNAME}'."
fi

# No make_server.sh call here anymore — the server's TLS certificate (nginx
# + mosquitto) now comes from Let's Encrypt further down, not from this CA.
# This CA's only remaining job is client certificates (below, and the
# dynamic ones plp-custom issues at runtime).

# MQTT client CA (mosquitto's trust anchor for dynamically issued client
# certificates) — independent of the clients-api CA above, see the
# separation note in pki-scripts/clients-mqtt/pki.conf.txt. The port is a
# fixed application constant, not a per-customer value, so it isn't asked
# for here — anyone needing a different port edits
# pki-scripts/clients-mqtt/pki.conf.txt directly.
PKI_CLIENTS_MQTT_DIR="$PKI_DIR/clients-mqtt"
MQTT_PORT=8883
MQTT_DNAME="mqtt_${MQTT_PORT}"
MQTT_CA_PEM="$PKI_CLIENTS_MQTT_DIR/CA/ca.${MQTT_DNAME}.pem"

if [[ -f "$MQTT_CA_PEM" ]]; then
  MQTT_CA_STATUS="MQTT CA already existed for '${MQTT_DNAME}' — reused, not regenerated."
else
  ( cd "$PKI_CLIENTS_MQTT_DIR" && ./make_ca.sh "$MQTT_PORT" )
  MQTT_CA_STATUS="MQTT CA newly created for '${MQTT_DNAME}'."
fi

# --- client certificate (bootstrap .p12 for API access) --------------------

CLIENT_P12_DIR="$PKI_CLIENTS_API_DIR/${DNAME}"
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

  ( cd "$PKI_CLIENTS_API_DIR" && ./make_client.sh "$P12_PASS" )
  CLIENT_CERT_STATUS="Client certificate created for '${DNAME}'."
  P12_PASSWORD_NOTE="$P12_PASS"
fi

# --- nginx (package + port-80 ACME vhost) -----------------------------

# Always run, never gated behind a "command -v nginx" check: apt-get install
# is idempotent on an already-healthy package, and — unlike a presence
# check — it also repairs a half-configured package left over from a prior
# failed install (a real case we hit: a manual "apt purge" plus a failed
# reinstall can leave the nginx binary present but the package broken).
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

# nginx's default server_names_hash_bucket_size is too small for a long
# server_name — a real case we hit: a 51-character UUID-based subdomain
# failed nginx -t with "could not build server_names_hash, you should
# increase server_names_hash_bucket_size". This is an http{}-level setting,
# can't be set inside a server{} block, so it can't just go in
# phraselock.conf/phraselock_80.conf — Debian's stock nginx.conf already
# includes /etc/nginx/conf.d/*.conf from within http{}, so a small file
# there is the least invasive way in without editing nginx.conf itself.
# 128 rather than the 64 nginx actually asked for, for headroom against
# future even-longer domains.
mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/phraselock-hash-bucket.conf << 'EOF'
server_names_hash_bucket_size 128;
EOF

# Sites this installer doesn't manage: drop the Debian sample entirely, only
# disable (don't delete) the stock default so it stays available as a
# reference but no longer conflicts with silent-drop.conf's default_server.
rm -f /etc/nginx/sites-enabled/test-site /etc/nginx/sites-available/test-site
rm -f /etc/nginx/sites-enabled/default

SITES_SRC_DIR="$SCRIPT_DIR/etc/nginx/sites-available"

# The port-80 ACME-challenge vhost has to exist and be reloaded into nginx
# *before* certbot runs below — certbot's webroot authenticator proves
# domain ownership by having Let's Encrypt fetch a token file from here over
# plain HTTP. The 443 vhost (phraselock.conf, needs the certificate that
# doesn't exist yet) is written further down, after certbot has run.
mkdir -p /var/www/certbot
sed "s|server_name .*;|server_name ${DNAME};|" \
  "$SITES_SRC_DIR/phraselock_80.conf" > /etc/nginx/sites-available/phraselock_80.conf
ln -sf /etc/nginx/sites-available/phraselock_80.conf /etc/nginx/sites-enabled/phraselock_80.conf

nginx -t
systemctl reload nginx 2>/dev/null || systemctl restart nginx

# --- certbot (Let's Encrypt) ---------------------------------------------
#
# Installed into its own venv under /opt/certbot rather than via apt/snap:
# Debian's certbot package pulls in snapd on some images, which this
# installer doesn't want as a dependency, and the venv method is the
# officially supported no-snap path from the Certbot project itself.
if [[ ! -x /opt/certbot/bin/certbot ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv libaugeas0
  python3 -m venv /opt/certbot
  /opt/certbot/bin/pip install --upgrade pip >/dev/null
  /opt/certbot/bin/pip install certbot
  ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
fi

LE_LIVE_DIR="/etc/letsencrypt/live/${DNAME}"
if [[ -f "${LE_LIVE_DIR}/fullchain.pem" ]]; then
  LE_STATUS="Let's Encrypt certificate already existed for '${DNAME}' — reused, not re-requested."
else
  certbot certonly --webroot -w /var/www/certbot \
    -d "$DNAME" -m "$LE_EMAIL" --agree-tos --no-eff-email --non-interactive --key-type ecdsa
  LE_STATUS="Let's Encrypt certificate newly issued for '${DNAME}'."
fi

# certbot's own systemd timer only ships with the apt package, not the pip/
# venv install used here — so a matching timer+service is written by hand.
# Written and (re-)enabled unconditionally, same reasoning as the apt-get
# install above: repairs a prior install where this step failed partway.
cat > /etc/systemd/system/certbot-renew.service << 'EOF'
[Unit]
Description=Certbot Renewal

[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --quiet
EOF

cat > /etc/systemd/system/certbot-renew.timer << 'EOF'
[Unit]
Description=Run Certbot Renewal twice daily

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer >/dev/null 2>&1 || true

# Deploy hooks: certbot runs every script under this directory after each
# successful renewal (initial issuance above does NOT trigger them, which is
# why the nginx/mosquitto cert wiring below still has to happen here too,
# not just in the hooks).
LE_HOOKS_DIR=/etc/letsencrypt/renewal-hooks/deploy
LE_HOOKS_SRC_DIR="$SCRIPT_DIR/etc/letsencrypt/renewal-hooks/deploy"
mkdir -p "$LE_HOOKS_DIR"
sed "s|__DNAME__|${DNAME}|g" "$LE_HOOKS_SRC_DIR/01-reload-nginx.sh"     > "$LE_HOOKS_DIR/01-reload-nginx.sh"
sed "s|__DNAME__|${DNAME}|g" "$LE_HOOKS_SRC_DIR/02-reload-mosquitto.sh" > "$LE_HOOKS_DIR/02-reload-mosquitto.sh"
chmod +x "$LE_HOOKS_DIR/01-reload-nginx.sh" "$LE_HOOKS_DIR/02-reload-mosquitto.sh"

# --- nginx (certs + 443 vhost) -------------------------------------------

# Certs directory is fully replaced on every run, rebuilt from the PKI/LE
# artifacts generated above — never hand-edited, so nothing of value is lost.
NGINX_CERTS_DIR=/etc/nginx/certs
rm -rf "$NGINX_CERTS_DIR"
mkdir -p "$NGINX_CERTS_DIR"

cp "$PKI_CLIENTS_API_DIR/CA/ca.${DNAME}.pem" "$NGINX_CERTS_DIR/"

# server.crt/server.key are symlinks straight into Let's Encrypt's live
# directory — not a copy — so a renewal (which replaces those symlinks
# atomically) is picked up by a plain reload, no re-copy needed. This is
# safe for nginx specifically because its master process, which reads the
# TLS private key before dropping privileges, still runs as root.
ln -sf "${LE_LIVE_DIR}/fullchain.pem" "$NGINX_CERTS_DIR/server.crt"
ln -sf "${LE_LIVE_DIR}/privkey.pem"   "$NGINX_CERTS_DIR/server.key"
ln -sf "ca.${DNAME}.pem"              "$NGINX_CERTS_DIR/ca.client.pem"

sed "s|server_name .*;|server_name ${DNAME};|" \
  "$SITES_SRC_DIR/phraselock.conf" > /etc/nginx/sites-available/phraselock.conf
cp "$SITES_SRC_DIR/silent-drop.conf" /etc/nginx/sites-available/silent-drop.conf

ln -sf /etc/nginx/sites-available/phraselock.conf /etc/nginx/sites-enabled/phraselock.conf
ln -sf /etc/nginx/sites-available/silent-drop.conf  /etc/nginx/sites-enabled/silent-drop.conf

mkdir -p /etc/nginx/phraselock.d

nginx -t
systemctl reload nginx 2>/dev/null || systemctl restart nginx

NGINX_STATUS="nginx installed and reloaded, phraselock.conf serving '${DNAME}' (Let's Encrypt)."

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

# Unlike nginx, mosquitto drops root and runs as its own unprivileged user,
# so it cannot read Let's Encrypt's privkey.pem in place (root:root 600).
# Its own certs directory therefore holds an actual, group-readable copy —
# refreshed here on install and by the 02-reload-mosquitto.sh deploy hook on
# every renewal — rather than a symlink into /etc/letsencrypt/live. (Symlink
# ownership/mode is irrelevant on Linux — access control always uses the
# target file's own permissions — so only fullchain.pem/privkey.pem below
# need an explicit chown/chmod; server.crt/server.key don't.) Named to match
# nginx's server.crt/server.key exactly — same artifact, same role, same name.
#
# No "cafile" pointing at the clients-api CA here (an earlier version of
# this installer had one, via a generically-named "bundle.crt") — that would
# let an API bootstrap certificate also pass this broker's client-certificate
# check, which defeats the whole point of clients-api and clients-mqtt being
# separate CAs (see pki-scripts/clients-mqtt/pki.conf.txt). Trust for
# incoming MQTT client certificates comes exclusively from the capath below.
MOSQ_CERTS_DIR=/etc/mosquitto/certs
mkdir -p "$MOSQ_CERTS_DIR"
rm -f "$MOSQ_CERTS_DIR/bundle.crt" "$MOSQ_CERTS_DIR/cert.crt" "$MOSQ_CERTS_DIR/cert.key"
ln -sf fullchain.pem "$MOSQ_CERTS_DIR/server.crt"
ln -sf privkey.pem   "$MOSQ_CERTS_DIR/server.key"
cp "${LE_LIVE_DIR}/fullchain.pem" "${LE_LIVE_DIR}/privkey.pem" "$MOSQ_CERTS_DIR/"
chown root:mosquitto "$MOSQ_CERTS_DIR/fullchain.pem" "$MOSQ_CERTS_DIR/privkey.pem"
chmod 644 "$MOSQ_CERTS_DIR/fullchain.pem"
chmod 640 "$MOSQ_CERTS_DIR/privkey.pem"

# The MQTT client CA is staged under mosquitto's own certs directory — not
# nginx's, which has no functional relationship to it at all — instead of
# pointing capath straight at the PKI scripts' own output. pki-scripts stays
# just the factory that produces cert material; /etc/mosquitto/certs is
# where mosquitto's own deployed copies live.
MQTT_CLIENT_CA_DIR="$MOSQ_CERTS_DIR/client-ca/${MQTT_DNAME}"
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
    | (grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' || true) | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
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
# client CA's key (bootstrap client certs; this CA no longer signs a server
# certificate, see the pki.conf.txt comment) and the MQTT CA's key+cert
# (dynamically issued MQTT client certs) — same set as on hmx.
cp "$PKI_CLIENTS_API_DIR/CA/ca.${DNAME}.key" "$CUSTOM_DIR/certs/CA/"
cp "$PKI_CLIENTS_MQTT_DIR/CA/ca.${MQTT_DNAME}.key" "$PKI_CLIENTS_MQTT_DIR/CA/ca.${MQTT_DNAME}.pem" "$CUSTOM_DIR/certs/CA/"

chown -R phraselock:phraselock "$CUSTOM_DIR"
chmod 600 "$CUSTOM_DIR/certs/CA/"*.key

cp "$CUSTOM_SRC_DIR/plp-custom.service" "$CUSTOM_DIR/plp-custom.service"
ln -sf "$CUSTOM_DIR/plp-custom.service" /etc/systemd/system/plp-custom.service

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
# which is easy to miss once whiptail redraws the screen. The wall of
# "already existed / reused" status lines above can read as "everything is
# just done" — the ACTION NEEDED block below is deliberately loud so the
# two things that still need a human (cert import, permanent JWT) don't get
# lost in it. File paths are deliberately NOT inlined here (only referenced
# via README.txt) since a long domain-based path can overflow this
# fixed-width dialog with no wrap point.
"$DIALOG" --title "PLP Server Setup" --msgbox \
"${CA_STATUS}
${LE_STATUS}

${MQTT_CA_STATUS}

${CLIENT_CERT_STATUS}

${NGINX_STATUS}

${MOSQUITTO_STATUS}
${MQTT_PASSWD_STATUS}

${JAVA_STATUS}
${CUSTOM_STATUS}
${JWT_STATUS}

============================================================
ACTION NEEDED — not fully usable yet without these two steps:
============================================================
1) Import the client certificate (.p12) on any PC/Mac that needs
   API access. Path, password and store-location all matter — see
   /opt/phraselock/README.txt.

2) The plp-core token just installed is TEMPORARY and WILL expire.
   Request a permanent one from PhraseLock — see
   /opt/phraselock/README.txt for where to put it.

Full details, including exact file paths, in:
  /opt/phraselock/README.txt
  /opt/phraselock/credentials.txt (passwords)" 36 78
