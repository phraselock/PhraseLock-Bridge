PLPProxyClient — Setup Instructions
====================================

This installer connects this device to a PLPProxyServer via an frp tunnel.
Before running install.sh, three files from the proxy server must be placed
into the certs-in/ folder next to install.sh. This step is NOT automated —
it requires access to the proxy server and a transport method you trust.

Step 1 — On the PROXY SERVER, issue a certificate for this client:

    cd /opt/phraselock/pki-scripts-proxy/server
    ./make_client_frp.sh <a-name-for-this-client> <a-password-for-the-p12>

  <a-name-for-this-client> can be anything that identifies this device
  (e.g. a hostname). This creates a folder ./<name>.FRP/ with several files.

Step 2 — Copy exactly these three files onto THIS device, into certs-in/:

    <name>.FRP/<name>.crt          ->  certs-in/<name>.crt
    <name>.FRP/<name>.key          ->  certs-in/<name>.key
    CA/ca.<proxy-server-address>.pem  ->  certs-in/ca.<proxy-server-address>.pem

  (The .p12 and .pem files under <name>.FRP/ are convenience bundles for
  other tools — not needed here. Only .crt and .key from that folder.)

Step 3 — Choose a transport method you trust for this copy (e.g. scp over
  SSH, a USB stick, an already-secure channel). This is not automated on
  purpose: whoever controls this transport step controls the resulting
  trust relationship.

  Easiest: run the ready-made scp commands shown at the end of the
  PLPProxyServer installation (also in its README.txt) — they already have
  the right paths filled in. Works the same on Mac, Linux and Windows:
  Windows 10/11 ships scp.exe out of the box (in PowerShell, use "scp.exe"
  explicitly — plain "scp" may be aliased to something else).

    - ca.<...>.pem is a public certificate — no secret, but it must not be
      swapped for a different one in transit, or this device would end up
      trusting the wrong proxy server.
    - <name>.key is a PRIVATE KEY — this one genuinely is a secret and
      must not be exposed to anyone else during transport.

Step 4 — Once all three files are in certs-in/, run:

    ./install.sh

  It will ask for the proxy server's address and its auth.token (shown at
  the end of the PLPProxyServer installation), then set up and start frpc.
