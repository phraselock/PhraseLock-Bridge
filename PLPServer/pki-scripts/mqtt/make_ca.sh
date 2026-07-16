#!/bin/bash
#
# make_ca.sh – creates the root CA (key + self-signed certificate) for a
# Mosquitto tenant.
#
# Usage: ./make_ca.sh <port>
#   <port> : Mosquitto port of this tenant (e.g. 8883). Combined with
#            dname_base from pki.conf.txt this gives the dname
#            "<dname_base>_<port>" (e.g. "mqtt_8883") – so each port gets
#            its own CA.
#
# Subject and crypto parameters come from pki.conf.txt. WARNING: run this
# only once per tenant/port – re-running it would overwrite the existing
# CA and invalidate all previously signed server/client certificates of
# that tenant. The script therefore refuses to run if a CA with the same
# name already exists under ca_dir.
#
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

DNAME=$(resolve_dname "${1:-}")
derive_ca_paths

if [[ -f "$CA_KEY" || -f "$CA_PEM" ]]; then
  echo "Error: CA already exists under ${CA_DIR} (${CANAME}.key/.pem)." >&2
  echo "       Only delete it deliberately before creating a new CA." >&2
  exit 1
fi

mkdir -p "$CA_DIR"
trap 'cleanup_tmp "$CANAME"' EXIT

ca_subject="/C=${SUBJ_C}/ST=${SUBJ_ST}/L=${SUBJ_L}/OU=${SUBJ_OU}/O=${SUBJ_O}/CN=${DNAME}/emailAddress=${SUBJ_EMAIL}"

# x509 v3 extensions for a CA are passed inline instead of via a separate
# .cnf file – this keeps pki.conf.txt the single source of truth for dname.
CA_EXT=$(cat <<EOF
[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
)

openssl ecparam -name "$EC_CURVE" -genkey -noout -out "${CANAME}.key"
chmod 600 "${CANAME}.key"

openssl req -new -x509 -sha256 -key "${CANAME}.key" -out "${CANAME}.pem" \
    -days "$DURATION" -subj "$ca_subject" \
    -extensions v3_ca -config <(echo "$CA_EXT")

cp "${CANAME}.key" "${CANAME}.pem" "${CA_DIR}/"

# Also store the CA key as PKCS#8 (expected by some tools/libraries)
openssl pkcs8 -topk8 -nocrypt -in "${CA_DIR}/${CANAME}.key" -out "${CA_DIR}/${CANAME}.pkcs8.key"

# Also store the CA certificate as DER (e.g. for clients/tools that
# cannot read PEM)
openssl x509 -in "${CA_DIR}/${CANAME}.pem" -outform der -out "${CA_DIR}/${CANAME}.der"

echo "Done. CA is under ${CA_DIR}/${CANAME}.{key,pem,pkcs8.key,der}"
