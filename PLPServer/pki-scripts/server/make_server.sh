#!/bin/bash
#
# make_server.sh – creates a server certificate (e.g. for nginx or an MQTT
# broker) and signs it with the central CA.
#
# Usage: ./make_server.sh
#
# CN/SAN come from dname in pki.conf.txt. IPv4 addresses automatically get
# an IP SAN, anything else a DNS SAN.
#
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

DNAME=$(resolve_dname)
derive_ca_paths

require_file "$CA_KEY"
require_file "$CA_PEM"

CN="$DNAME"
trap 'cleanup_tmp "$CN"' EXIT

server_subject="/C=${SUBJ_C}/ST=${SUBJ_ST}/L=${SUBJ_L}/OU=${SUBJ_OU}/O=${SUBJ_O}/CN=${CN}/emailAddress=${SUBJ_EMAIL}"
SAN=$(san_for "$CN")

SERVER_EXT=$(cat <<EOF
[ v3_req ]
subjectAltName = ${SAN}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
EOF
)

openssl ecparam -name "$EC_CURVE" -genkey -noout -out "${CN}.key"
chmod 600 "${CN}.key"

openssl req -new -sha256 -key "${CN}.key" -out "${CN}.csr" -subj "$server_subject"

openssl x509 -req -sha256 -in "${CN}.csr" \
    -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
    -out "${CN}.crt" -days "$DURATION" \
    -extensions v3_req -extfile <(echo "$SERVER_EXT")

mkdir -p ./server
cp "${CN}.key" "${CN}.crt" ./server/

echo "Done. Server certificate is under ./server/${CN}.{key,crt}"
