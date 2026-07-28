#!/bin/bash
# PhraseLock-Bridge bootstrap installer
# Downloads the latest release from GitHub and runs the chosen package installer.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | sudo bash
#
set -euo pipefail

GITHUB_REPO="phraselock/PhraseLock-Bridge"
TITLE="PhraseLock-Bridge Setup"

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: this installer must run as root (sudo)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dialog tool
# ---------------------------------------------------------------------------
DIALOG=$(command -v whiptail 2>/dev/null || command -v dialog 2>/dev/null || true)
if [[ -z "$DIALOG" ]]; then
  echo "Installing whiptail..." >&2
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail
  DIALOG=$(command -v whiptail)
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
# Which package?
# ---------------------------------------------------------------------------
CHOICE=$("$DIALOG" --title "$TITLE" --menu \
  "Which component do you want to install?" 14 65 3 \
  "PLPServer"      "Customer device (Raspberry Pi / Linux server)" \
  "PLPProxyServer" "Central proxy — only needed without a fixed IP" \
  "PLPProxyClient" "Customer device tunnel client — needs PLPProxyServer first" \
  3>&1 1>&2 2>&3) || { echo "Aborted." >&2; exit 1; }

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
