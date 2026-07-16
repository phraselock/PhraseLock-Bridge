PLPProxyServer — Handing Off the Client Certificate
=====================================================

install.sh already set up this server's own CA, server certificate, frps —
and, since this proxy is single-tenant (exactly one client, ever), also
issued that one client's certificate automatically. Its file locations were
shown at the end of the install.sh run. This file explains the one
remaining manual step: getting those files onto the client device.

Step 1 — Copy exactly these three files...

    __CLIENT_OUT_DIR__/__CLIENT_NAME__.crt   (the issued client certificate)
    __CLIENT_OUT_DIR__/__CLIENT_NAME__.key   (its private key)
    __PKI_SERVER_DIR__/CA/ca.__DNAME__.pem   (this server's CA public certificate)

  ...onto the client device, into the certs-in/ folder next to
  PLPProxyClient's install.sh (i.e. PLPProxyClient/certs-in/). Keep their
  original filenames — install.sh there looks for any *.crt, any *.key,
  and a ca.*.pem, so exact names don't matter, only that all three are
  present. If they're missing, PLPProxyClient's install.sh aborts with an
  error instead of continuing without them, since frpc.toml's certFile /
  keyFile / trustedCaFile entries would otherwise point at files that
  don't exist.

  Use a transport you trust (scp, USB stick, ...) — this is not automated
  on purpose, since whoever controls that transport step controls the
  resulting trust relationship. __CLIENT_NAME__.key is a private key and
  must be treated as a secret; ca.__DNAME__.pem is public but must not be
  swapped for a different one in transit, or the client would end up
  trusting the wrong proxy server.

Step 2 — The client also needs this server's auth.token — see
  credentials.txt next to this file.

Issuing a certificate for a different/replacement client
-----------------------------------------------------------

install.sh only issues the client certificate once (skipped on repeated
runs if it already exists). To issue a new one — e.g. replacing a lost
device — run manually:

    cd /opt/phraselock/pki-scripts-proxy/server
    ./make_client_frp.sh <a-name>

  This creates a folder ./<a-name>.FRP/ with the same three-file structure
  as above.

Migrating this proxy to new hardware
-------------------------------------

If you're moving PLPProxyServer to a new machine and want already-issued
client certificates to remain valid, don't let install.sh generate a new
CA — import the old one instead:

    1. From the old server, copy /opt/phraselock/pki-scripts-proxy/server/
       CA/ca.<old-address>.key, ca.<old-address>.pem and (if present)
       ca.<old-address>.pkcs8.key onto the new machine.
    2. Rename them to certs-in/ca.key, certs-in/ca.pem and
       certs-in/ca.pkcs8.key next to install.sh on the new machine.
    3. Run install.sh — it detects the files in certs-in/ and asks whether
       to import them instead of generating a fresh CA.

Notes:
  - Each client needs its own certificate — running make_client_frp.sh
    again with a different name issues an independent one, unrelated to
    any other client's.
  - This server is single-tenant by design (see install.sh) — it only
    forwards to the one set of ports (30000/60000) configured in
    /etc/nginx/nginx.conf and /etc/frp/frps.toml. Issuing multiple client
    certificates does not by itself make this a multi-tenant proxy.
