This directory's certificate/key material for mosquitto's TLS listener
(port 8883) is NOT authoritative here — nothing in this directory is a
true original except the symlinks' targets elsewhere.

  fullchain.pem, privkey.pem
      A permission-adjusted COPY, not the original — copied from
      /etc/letsencrypt/live/<domain>/{fullchain,privkey}.pem (certbot /
      Let's Encrypt) and re-owned root:mosquitto so mosquitto (which does
      not run as root) can read them. Refreshed automatically after every
      certificate renewal by
      /etc/letsencrypt/renewal-hooks/deploy/02-reload-mosquitto.sh.
      Never edit these by hand — they get overwritten on the next
      renewal, and won't match /etc/letsencrypt's actual current
      certificate in the meantime if you do.

  server.crt, server.key
      Plain symlinks to fullchain.pem/privkey.pem above (same files,
      under the names mosquitto's config expects).

client-ca.8883.d/ (mosquitto's client-certificate trust store) is
symlinked straight to this installation's own PKI under
/opt/phraselock/pki-scripts/clients-mqtt/ — no copy at all there. See
that directory, and PhraseLock-Bridge's README.md ("Certificate flow
between installers"), for the actual source of truth behind everything
in this directory.
