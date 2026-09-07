#!/bin/bash
set -euo pipefail

# Undoes what install.sh set up. frps is entirely our own (a manually
# installed binary, not a package) and is always fully removed. Whether the
# nginx package itself gets purged, and whether the CA under
# /opt/phraselock/pki-scripts-proxy gets deleted, are both asked
# interactively — the CA question matters because deleting it permanently
# invalidates the server certificate and every frp client certificate
# issued against it so far.

# Root is checked here rather than assumed via a hardcoded "sudo" in the
# documented usage: plenty of real servers already have root logged in by
# default (the account that exists from day one) and never had sudo
# installed at all — "sudo bash uninstall.sh" then fails at the shell
# level, before this script ever runs, with a bare "sudo: command not
# found". $0 is already a real file here (never piped), so re-exec'ing
# through sudo needs no re-download.
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  else
    echo "Error: this uninstaller must run as root, and 'sudo' is not installed on this system. Log in as root directly and re-run." >&2
    exit 1
  fi
fi

DIALOG=$(command -v whiptail || command -v dialog)

# --- frps (always fully removed — entirely ours, not a package) ------------

systemctl stop frps 2>/dev/null || true
systemctl disable frps >/dev/null 2>&1 || true
rm -f /etc/systemd/system/frps.service
rm -f /usr/local/bin/frps
rm -rf /etc/frp
systemctl daemon-reload

# --- nginx (package asked about) --------------------------------------------

systemctl stop nginx 2>/dev/null || true
systemctl disable nginx >/dev/null 2>&1 || true

if "$DIALOG" --title "PLP Proxy Server Uninstall" --yesno \
"Also completely remove the nginx package (apt purge), not just stop it?

If kept, its config file still contains this installer's stream-forward setup — you'd need to fix that manually before reusing nginx for something else." 12 70; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
  NGINX_STATUS="nginx package purged."
else
  NGINX_STATUS="nginx package left installed (stopped, disabled) — its config still has our stream-forward setup."
fi

# --- CA / pki-scripts-proxy (asked, not automatic) --------------------------

if [[ -d /opt/phraselock/pki-scripts-proxy ]]; then
  if "$DIALOG" --title "PLP Proxy Server Uninstall" --yesno \
"Also delete the CA under /opt/phraselock/pki-scripts-proxy?

This permanently invalidates the server certificate and every frp client certificate issued against it so far. There is no way back except creating a brand new CA." 14 70; then
    rm -rf /opt/phraselock/pki-scripts-proxy
    CA_STATUS="CA deleted."
  else
    CA_STATUS="CA kept at /opt/phraselock/pki-scripts-proxy."
  fi
else
  CA_STATUS="No CA found under /opt/phraselock/pki-scripts-proxy — nothing to delete."
fi

"$DIALOG" --title "PLP Proxy Server Uninstall" --msgbox \
"Uninstall complete.

frps (binary, config, certs, systemd unit) removed entirely.
${NGINX_STATUS}

${CA_STATUS}" 16 74
