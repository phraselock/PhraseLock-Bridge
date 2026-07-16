#!/bin/bash
set -euo pipefail

# Undoes what install.sh set up. Everything here is entirely our own (a
# manually installed binary + config, no package involved), so unlike
# PLPServer/PLPProxyServer there's nothing to ask about — it's all removed
# unconditionally. The issued client certificate is lost in the process;
# reconnecting later needs a fresh one from the proxy server's
# make_client_frp.sh.

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
