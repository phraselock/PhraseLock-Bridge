#!/bin/bash
#
# make_client.sh – creates a client certificate (mTLS) for a Mosquitto
# tenant and signs it with that tenant's CA.
#
# Template without immediate practical use: in the real setup, no client
# certificate is created upfront – after bootstrapping (see the server
# template, client_eku_oid_bootstrap) an API dynamically issues client
# certificates using the client_eku_oid_dynamic OID. This script is kept
# as a reference/template in case a client certificate is ever needed
# manually for this tenant. Only creates a key + certificate, no .p12 (no
# manual import on client/server needed).
#
# Usage: ./make_client.sh <port>
#   <port> : Mosquitto port of the tenant (e.g. 8883), must match the CA
#            from make_ca.sh.
#
# The EKU OID is fixed to client_eku_oid_dynamic from pki.conf.txt.
#
# The CN of the client certificate equals "<dname_base>_<port>" (same
# value as the CA).
#
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

DNAME=$(resolve_dname "${1:-}")
derive_ca_paths

require_file "$CA_KEY"
require_file "$CA_PEM"

CN="$DNAME"
EKU_OID=$(cfg client_eku_oid_dynamic)

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
openssl pkcs8 -topk8 -nocrypt -in "${CN}.key" -out "${CN}.pkcs8.key"

openssl req -new -sha256 -key "${CN}.key" -out "${CN}.csr" -subj "$client_subject"

openssl x509 -req -sha256 -in "${CN}.csr" \
    -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
    -out "${CN}.crt" -days "$DURATION" \
    -extensions client_cert -extfile <(echo "$CLIENT_EXT")


mkdir -p "./${CN}"
cp "${CN}.key" "${CN}.crt" "${CN}.pkcs8.key" "./${CN}/"

echo "Done. Artifacts are under ./${CN}/"
echo "  ${CN}.crt  – certificate"
echo "  ${CN}.key  – private key"
echo "  ${CN}.pkcs8.key – private key (PKCS8, unencrypted)"