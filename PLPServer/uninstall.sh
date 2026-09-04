#!/bin/bash
set -euo pipefail

# Undoes what install.sh set up: configuration/certs/services this installer
# created are always removed. Whether the nginx/mosquitto packages themselves
# get purged, and whether the CA under /opt/phraselock/pki-scripts gets
# deleted, are both asked interactively — the CA question matters because
# deleting it permanently invalidates every certificate issued so far.

DIALOG=$(command -v whiptail || command -v dialog)

# --- plp-custom --------------------------------------------------------

systemctl stop plp-custom 2>/dev/null || true
systemctl disable plp-custom >/dev/null 2>&1 || true
rm -f /etc/systemd/system/plp-custom.service
systemctl daemon-reload
rm -rf /opt/phraselock/custom

# --- mosquitto -----------------------------------------------------------

systemctl stop mosquitto 2>/dev/null || true
systemctl disable mosquitto >/dev/null 2>&1 || true
rm -f /etc/mosquitto/mosquitto.conf /etc/mosquitto/mosquitto_8883.conf
rm -rf /etc/mosquitto/conf_8883.d /etc/mosquitto/certs /etc/mosquitto/client-ca.8883.d
rm -f /etc/mosquitto/.passwd_8883

# --- nginx ---------------------------------------------------------------

rm -f /etc/nginx/sites-enabled/phraselock.conf /etc/nginx/sites-enabled/silent-drop.conf /etc/nginx/sites-enabled/phraselock_80.conf
rm -f /etc/nginx/sites-available/phraselock.conf /etc/nginx/sites-available/silent-drop.conf /etc/nginx/sites-available/phraselock_80.conf
rm -rf /etc/nginx/certs
rm -rf /var/www/certbot

# Re-enable the stock Debian default site that install.sh disabled — it was
# only unlinked from sites-enabled, never deleted, so this is a clean revert.
if [[ -f /etc/nginx/sites-available/default ]]; then
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi

# --- certbot / Let's Encrypt ----------------------------------------------

# The renewal timer is always stopped — there's nothing left here for it to
# renew for once nginx/mosquitto's config is gone. The certificate itself
# (and the certbot venv) is only deleted on confirmation: unlike the CA
# below, re-obtaining it is quick and free, but this still asks first since
# a reinstall within the same domain/rate-limit window benefits from reusing
# it (install.sh already treats an existing certificate as reusable).
systemctl stop certbot-renew.timer 2>/dev/null || true
systemctl disable certbot-renew.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/certbot-renew.timer /etc/systemd/system/certbot-renew.service
systemctl daemon-reload
rm -rf /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh /etc/letsencrypt/renewal-hooks/deploy/02-reload-mosquitto.sh

if [[ -d /etc/letsencrypt ]] || [[ -x /opt/certbot/bin/certbot ]]; then
  if "$DIALOG" --title "PLP Server Uninstall" --yesno \
"Also delete the Let's Encrypt certificate(s) under /etc/letsencrypt and the certbot installation under /opt/certbot?

A reinstall can reuse an existing certificate if it's kept." 11 70; then
    [[ -x /opt/certbot/bin/certbot ]] && /opt/certbot/bin/certbot delete --non-interactive >/dev/null 2>&1 || true
    rm -rf /etc/letsencrypt /opt/certbot
    rm -f /usr/bin/certbot
    LE_STATUS="Let's Encrypt certificate(s) and certbot deleted."
  else
    LE_STATUS="Let's Encrypt certificate(s) and certbot kept (renewal timer stopped)."
  fi
else
  LE_STATUS="No Let's Encrypt certificate found — nothing to delete."
fi

# --- packages (asked, not automatic) --------------------------------------

if "$DIALOG" --title "PLP Server Uninstall" --yesno \
"Also completely remove the nginx and mosquitto packages (apt purge), not just their configuration?" 10 70; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common mosquitto
  PACKAGE_STATUS="nginx and mosquitto packages purged."

  # A separate, explicit question — "apt autoremove" is not scoped to what
  # was just purged, it sweeps every package currently marked as
  # auto-installed-and-unneeded system-wide (a real case we hit while
  # testing: it took two long-orphaned old kernel images with it, unrelated
  # to nginx/mosquitto). Bundling that into the purge question above would
  # silently give this uninstaller a much bigger blast radius than "remove
  # what PLPServer installed" — so it needs its own informed yes/no.
  if "$DIALOG" --title "PLP Server Uninstall" --yesno \
"Also run 'apt autoremove' to clean up now-orphaned dependencies?

This is NOT limited to nginx/mosquitto's own dependencies — it removes every package currently marked auto-installed-and-unneeded system-wide, which may include things unrelated to PLPServer (e.g. old kernel images)." 12 74; then
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
    AUTOREMOVE_STATUS="apt autoremove run."
  else
    AUTOREMOVE_STATUS="apt autoremove skipped."
  fi
else
  systemctl reload nginx 2>/dev/null || true
  PACKAGE_STATUS="nginx and mosquitto packages left installed."
  AUTOREMOVE_STATUS=""
fi

# --- CA / pki-scripts (asked, not automatic) ------------------------------

if [[ -d /opt/phraselock/pki-scripts ]]; then
  if "$DIALOG" --title "PLP Server Uninstall" --yesno \
"Also delete the CA under /opt/phraselock/pki-scripts?

This permanently invalidates every certificate issued so far (server, MQTT, client). There is no way back except creating a brand new CA." 14 70; then
    rm -rf /opt/phraselock/pki-scripts
    CA_STATUS="CA deleted."
  else
    CA_STATUS="CA kept at /opt/phraselock/pki-scripts."
  fi
else
  CA_STATUS="No CA found under /opt/phraselock/pki-scripts — nothing to delete."
fi

"$DIALOG" --title "PLP Server Uninstall" --msgbox \
"Uninstall complete.

plp-custom, mosquitto and nginx configuration/certs removed.
${PACKAGE_STATUS}
${AUTOREMOVE_STATUS}

${LE_STATUS}

${CA_STATUS}" 18 70
