#!/bin/bash
set -euo pipefail

# Undoes what install.sh set up. Everything here is entirely our own (a
# manually installed binary + config, no package involved), so unlike
# PLPServer/PLPProxyServer there's nothing to ask about — it's all removed
# unconditionally. The issued client certificate is lost in the process;
# reconnecting later needs a fresh one from the proxy server's
# make_client_frp.sh.

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

systemctl stop frpc 2>/dev/null || true
systemctl disable frpc >/dev/null 2>&1 || true
rm -f /etc/systemd/system/frpc.service
rm -f /usr/local/bin/frpc
rm -rf /etc/frp
systemctl daemon-reload

"$DIALOG" --title "PLP Proxy Client Uninstall" --msgbox \
"Uninstall complete.

frpc (binary, config, certs, systemd unit) removed entirely.

To reconnect later, a new client certificate must be issued again on the proxy server (make_client_frp.sh) and copied into certs-in/ before reinstalling." 14 74
