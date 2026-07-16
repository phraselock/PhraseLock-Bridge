#!/bin/bash
set -euo pipefail

# Builds the three distributable tar.xz packages from this directory's
# PLPServer/PLPProxyServer/PLPProxyClient source trees.
#
# Usage: ./build-tars.sh [version]
#   [version]  optional, e.g. "1.0.0" — defaults to today's date (YYYYMMDD)
#              if omitted. Ends up in the output filename only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="${1:-$(date +%Y%m%d)}"

# pki-scripts/*/CA and certs-in/ must always be empty in the source tree —
# CA/ only ever gets created by make_ca.sh at install time, and certs-in/
# is where an operator drops certificates in manually before running
# install.sh. If either has a file in it here, something leaked in by
# accident (e.g. a local test run) and needs to be cleaned up by hand —
# refuse to build rather than silently filtering it out, so a real leak
# can't quietly end up "handled" without anyone noticing.
for PROJECT in PLPServer PLPProxyServer PLPProxyClient; do
  [[ -d "$PROJECT" ]] || continue
  while IFS= read -r -d '' f; do
    echo "Error: unexpected file found, refusing to build: $f" >&2
    exit 1
  done < <(find "$PROJECT" \( -path '*/pki-scripts/*/CA/*' -o -path '*/certs-in/*' \) -type f ! -name '.gitkeep' -print0 2>/dev/null)
done

# plp-custom-*.jar isn't tracked in this repo (build output of the separate
# plp-custom project) — must be dropped in manually before building, or
# the PLPServer package would silently ship without it.
if ! ls PLPServer/opt/phraselock/custom/plp-custom-*.jar >/dev/null 2>&1; then
  echo "Error: no plp-custom-*.jar found in PLPServer/opt/phraselock/custom/ — copy the current build there first." >&2
  exit 1
fi

EXCLUDES=(
  --exclude '*.DS_Store'
  --exclude '._*'
  --exclude '.gitkeep'
)

for PROJECT in PLPServer PLPProxyServer PLPProxyClient; do
  TARBALL="${PROJECT}-${VERSION}.tar.xz"
  echo "Building ${TARBALL} ..."
  tar "${EXCLUDES[@]}" -cJf "$TARBALL" "$PROJECT"
  echo "  -> $(pwd)/${TARBALL}"
done

echo "Done."
