#!/bin/bash
#
# make_frp_client.sh – creates a client certificate (mTLS) for frpc
# (frp reverse-tunnel authentication) and signs it with the central CA.
#
# Unlike make_client.sh (which creates the ONE bootstrap Phrase-Lock
# client cert with a fixed CN = dname), this script creates one
# frp-specific client certificate per <IP address>, so you can issue a
# separate, individually revocable certificate for each customer Pi /
# VPS pairing.
#
# The certificate only gets extendedKeyUsage = clientAuth (no bootstrap
# OID) since this is not a Phrase-Lock enrollment certificate, just an
# frpc authentication credential against frps.
#
# Usage: ./make_frp_client.sh <IP address>
#   <IP address>     : identifies this frp client (e.g. the VPS or
#                       customer-facing IP this tunnel belongs to).
#                       Used as CN and as the output folder name
#                       (<IP address>.FRP).
#
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
DNAME=$(resolve_dname)
derive_ca_paths
require_file "$CA_KEY"
require_file "$CA_PEM"

IP_ARG="${1:-}"

if [[ -z "$IP_ARG" ]]; then
  echo "Error: usage: $0 <IP address>" >&2
  exit 1
fi

# DNAME is only used above to derive the CA file paths (same CA as
# everywhere else). The certificate itself uses the IP address as CN,
# independent of DNAME.
CN="$IP_ARG"
OUT_DIR="./${IP_ARG}.FRP"

trap 'cleanup_tmp "$CN"' EXIT

client_subject="/C=${SUBJ_C}/ST=${SUBJ_ST}/L=${SUBJ_L}/OU=${SUBJ_OU}/O=${SUBJ_O}/CN=${CN}/emailAddress=${SUBJ_EMAIL}"

CLIENT_EXT=$(cat <<EOF
[ client_cert ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
EOF
)

openssl ecparam -name "$EC_CURVE" -genkey -noout -out "${CN}.key"
openssl req -new -sha256 -key "${CN}.key" -out "${CN}.csr" -subj "$client_subject"
openssl x509 -req -sha256 -in "${CN}.csr" \
    -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
    -out "${CN}.crt" -days "$DURATION" \
    -extensions client_cert -extfile <(echo "$CLIENT_EXT")

mkdir -p "$OUT_DIR"
cp "${CN}.key" "${CN}.crt" "$OUT_DIR/"

echo "Done. Artifacts are under ${OUT_DIR}/"
echo "  ${CN}.crt  – certificate (use as frpc transport.tls.certFile)"
echo "  ${CN}.key  – private key (use as frpc transport.tls.keyFile)"
