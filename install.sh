#!/bin/bash
# PhraseLock-Bridge bootstrap installer
# Downloads the latest release from GitHub and runs the chosen package installer.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | sudo bash -s PLPServer
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | sudo bash -s PLPProxyServer
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | sudo bash -s PLPProxyClient
#
set -euo pipefail

# When piped straight into bash ("curl | sudo bash -s ...", no script-file
# argument), bash reads this entire script from stdin as it executes —
# which then competes with whiptail for that same stdin further down (in
# the inner, per-component install.sh this script execs into), breaking
# keyboard input in its dialogs (Tab to move between fields/buttons
# especially — confirmed broken without this guard). Re-exec from a real,
# freshly-downloaded copy of ourselves instead: bash then reads its
# commands from disk, leaving stdin free for whiptail. Skipped entirely
# when stdin already is a terminal (e.g. downloaded first, then run
# directly) — nothing to work around in that case.
if [[ ! -t 0 ]]; then
  TMP_SELF=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh" -o "$TMP_SELF"
  chmod +x "$TMP_SELF"
  # < /dev/tty matters here, not just cosmetic: without it, stdin stays
  # whatever it was before (the now-drained curl pipe), so "[[ ! -t 0 ]]"
  # would still be true on the re-exec'd copy too and this would loop
  # forever, re-downloading and re-exec'ing on every pass. Safe to redirect
  # now because bash reads the script from the file argument this time,
  # not from stdin — freeing stdin up for the terminal.
  exec bash "$TMP_SELF" "$@" < /dev/tty
fi

GITHUB_REPO="phraselock/PhraseLock-Bridge"
VALID_COMPONENTS="PLPServer PLPProxyServer PLPProxyClient"

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: this installer must run as root (sudo)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Component argument
# ---------------------------------------------------------------------------
CHOICE="${1:-}"
if [[ -z "$CHOICE" ]]; then
  echo "Usage: sudo bash install.sh <component>" >&2
  echo "  Components: ${VALID_COMPONENTS}" >&2
  exit 1
fi
if [[ ! " ${VALID_COMPONENTS} " =~ " ${CHOICE} " ]]; then
  echo "Error: unknown component '${CHOICE}'." >&2
  echo "  Valid components: ${VALID_COMPONENTS}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# curl / tar
# ---------------------------------------------------------------------------
for PKG in curl tar; do
  if ! command -v "$PKG" >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG"
  fi
done

# ---------------------------------------------------------------------------
# Fetch latest release from GitHub
# ---------------------------------------------------------------------------
echo "Fetching latest release info from GitHub (${GITHUB_REPO})..."
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")
VERSION=$(echo "$RELEASE_JSON" \
  | grep '"tag_name"' \
  | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ -z "$VERSION" ]]; then
  echo "Error: could not determine latest release version. Check your internet connection." >&2
  exit 1
fi

TARBALL="${CHOICE}-${VERSION#v}.tar.gz"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${TARBALL}"

# ---------------------------------------------------------------------------
# Download and extract
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Downloading ${TARBALL} (${VERSION})..."
curl -fsSL "$DOWNLOAD_URL" -o "${WORK_DIR}/${TARBALL}"

echo "Extracting..."
tar -xzf "${WORK_DIR}/${TARBALL}" -C "$WORK_DIR" 2>/dev/null || \
  tar -xzf "${WORK_DIR}/${TARBALL}" -C "$WORK_DIR"

# ---------------------------------------------------------------------------
# Hand off to the package's own install.sh
# ---------------------------------------------------------------------------
cd "${WORK_DIR}/${CHOICE}"
exec bash install.sh
