#!/bin/bash
#
# make_client.sh – creates the ONE bootstrap client certificate (mTLS) and
# signs it with the central CA.
#
# This script is only meant for the initial, manually installed .p12: it
# authenticates the client once against an API, which then itself
# (server-side) issues a dynamic client certificate using the
# client_eku_oid_dynamic OID – that part is NOT covered here, since it
# happens on the server, not in this PKI template.
#
# Usage: ./make_client.sh <P12 password>
#   <P12 password>  : password protecting the generated .p12 file.
#
# The EKU OID is fixed to client_eku_oid_bootstrap from pki.conf.txt.
#
# The CN of the client certificate equals dname from pki.conf.txt (same
# value as CA/server) – so there is exactly one bootstrap client CN per
# PKI instance. If a different CN is needed, just change dname in
# pki.conf.txt or use a second pki.conf.txt via PKI_CONFIG=...
#
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

DNAME=$(resolve_dname)
derive_ca_paths

require_file "$CA_KEY"
require_file "$CA_PEM"

CN="$DNAME"
P12PASS_ARG="${1:-}"
EKU_OID=$(cfg client_eku_oid_bootstrap)

if [[ -z "$P12PASS_ARG" ]]; then
  echo "Error: usage: $0 <P12 password>" >&2
  exit 1
fi

trap 'cleanup_tmp "$CN"' EXIT

client_subject="/C=${SUBJ_C}/ST=${SUBJ_ST}/L=${SUBJ_L}/OU=${SUBJ_OU}/O=${SUBJ_O}/CN=${CN}/emailAddress=${SUBJ_EMAIL}"

CLIENT_EXT=$(cat <<EOF
[ client_cert ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth, ${EKU_OID}
EOF
)

openssl ecparam -name "$EC_CURVE" -genkey -noout -out "${CN}.key"

openssl req -new -sha256 -key "${CN}.key" -out "${CN}.csr" -subj "$client_subject"

openssl x509 -req -sha256 -in "${CN}.csr" \
    -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
    -out "${CN}.crt" -days "$DURATION" \
    -extensions client_cert -extfile <(echo "$CLIENT_EXT")

# Password via environment variable, not the command line (avoids showing
# up in the process list / shell history).
export P12PASS="$P12PASS_ARG"
openssl pkcs12 -export -out "${CN}.p12" \
    -inkey "${CN}.key" -in "${CN}.crt" -certfile "$CA_PEM" \
    -passout env:P12PASS

openssl pkcs12 -in "${CN}.p12" -out "${CN}.pem" -nodes -passin env:P12PASS
unset P12PASS

mkdir -p "./${CN}"
cp "${CN}.pem" "${CN}.key" "${CN}.p12" "./${CN}/"

echo "Done. Artifacts are under ./${CN}/"
echo "  ${CN}.p12  – password-protected bundle for import on Mac/Windows"
echo "  ${CN}.pem  – unencrypted key+cert for nginx/Apache/curl"
echo "  ${CN}.key  – private key only"
