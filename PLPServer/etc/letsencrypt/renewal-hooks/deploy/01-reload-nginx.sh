#!/bin/bash
#
# 01-reload-nginx.sh - runs after every certbot renewal.
#
# nginx reads the certificate straight through /etc/nginx/certs/server.crt
# and server.key, which are symlinks into /etc/letsencrypt/live/__DNAME__/ -
# no copy needed, since the nginx master process (which reads the TLS key)
# runs as root. A reload is enough to pick up the renewed files.
#
systemctl reload nginx
