#!/bin/bash
#
# common.sh – shared functions for the PKI scripts.
#
# Sourced by make_ca.sh / make_server.sh / make_client.sh. Not meant to be
# executed on its own.
#
set -euo pipefail

PKI_CONFIG="${PKI_CONFIG:-./pki.conf.txt}"

if [[ ! -f "$PKI_CONFIG" ]]; then
  echo "Error: central config '$PKI_CONFIG' not found." >&2
  exit 1
fi

# Reads a value from the [ metadata ] section of $PKI_CONFIG.
# Aborts with an error if the key is missing or empty.
cfg() {
  local key="$1"
  local val
  val=$(grep "^[[:space:]]*${key}[[:space:]]*=" "$PKI_CONFIG" | head -n1 | cut -d'=' -f2- | xargs)
  if [[ -z "$val" ]]; then
    echo "Error: parameter '${key}' missing in ${PKI_CONFIG}" >&2
    exit 1
  fi
  echo "$val"
}

# Returns true (exit code 0) if $PKI_CONFIG defines the key.
cfg_has() {
  local key="$1"
  grep -q "^[[:space:]]*${key}[[:space:]]*=" "$PKI_CONFIG"
}

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "Error: required file missing: $f" >&2
    exit 1
  fi
}

# Removes all temporary working files for a CN (key/CSR/cert/...).
# Activated via "trap 'cleanup_tmp \"\$CN\"' EXIT" in the wrapper scripts,
# so it also runs on failure and cleans up partial results.
cleanup_tmp() {
  local pattern="$1"
  rm -f "${pattern}.key" "${pattern}.csr" "${pattern}.crt" "${pattern}.p12" "${pattern}.pem" "${pattern}.pkcs8.key" 2>/dev/null || true
}

# Returns "IP:<dname>" for IPv4 addresses, otherwise "DNS:<dname>" – used
# as the subjectAltName for server certificates.
san_for() {
  local name="$1"
  if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "IP:${name}"
  else
    echo "DNS:${name}"
  fi
}

# Determines the dname for this run.
#
# Two variants, depending on pki.conf.txt:
#   - "dname"      set directly: fixed value (e.g. the server IP for
#                   nginx). The optional port argument is ignored.
#   - "dname_base" set instead (no "dname"): for setups with multiple
#                   instances on different ports (e.g. several Mosquitto
#                   tenants). Here the port MUST be passed as the first
#                   argument to the caller (make_ca.sh/make_server.sh/
#                   make_client.sh); the result is "<dname_base>_<port>".
resolve_dname() {
  local port="${1:-}"
  if cfg_has dname_base; then
    if [[ -z "$port" ]]; then
      echo "Error: pki.conf.txt uses dname_base – port must be passed as the first argument." >&2
      exit 1
    fi
    echo "$(cfg dname_base)_${port}"
  else
    cfg dname
  fi
}

# Derives the CA file paths from the global $DNAME. Must be called after
# DNAME has been set (via resolve_dname).
derive_ca_paths() {
  CANAME="ca.${DNAME}"
  CA_KEY="${CA_DIR}/${CANAME}.key"
  CA_PEM="${CA_DIR}/${CANAME}.pem"
}

# ---------------------------------------------------------------------------
# Central parameters needed by all wrapper scripts (independent of
# dname/dname_base and therefore independent of the port)
# ---------------------------------------------------------------------------
EC_CURVE=$(cfg ec_curve)
DURATION=$(cfg duration)
CA_DIR=$(cfg ca_dir)

SUBJ_C=$(cfg subj_c)
SUBJ_ST=$(cfg subj_st)
SUBJ_L=$(cfg subj_l)
SUBJ_OU=$(cfg subj_ou)
SUBJ_O=$(cfg subj_o)
SUBJ_EMAIL=$(cfg subj_email)
