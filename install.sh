#!/bin/bash
# PhraseLock-Bridge bootstrap installer
# Downloads the latest release from GitHub and runs the chosen package installer.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | bash -s PLPServer
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | bash -s PLPProxyServer
#   curl -sSL https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh | bash -s PLPProxyClient
#
set -euo pipefail

# Root is checked here rather than assumed via a hardcoded "sudo" in the
# documented one-liner: plenty of real servers already have root logged in
# by default (the account that exists from day one) and never had sudo
# installed at all — "curl | sudo bash" then fails at the shell level,
# before this script ever runs, with a bare "sudo: command not found".
NEED_SUDO=false
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    NEED_SUDO=true
  else
    echo "Error: this installer must run as root, and 'sudo' is not installed on this system. Log in as root directly and re-run." >&2
    exit 1
  fi
fi

# Also re-exec when piped straight into bash ("curl | bash -s ...", no
# script-file argument): bash reads this entire script from stdin as it
# executes, which then competes with whiptail for that same stdin further
# down (in the inner, per-component install.sh this script execs into),
# breaking keyboard input in its dialogs (Tab to move between
# fields/buttons especially — confirmed broken without this guard). Both
# cases share one re-exec so a non-root user on a pipe doesn't trigger it
# twice.
if [[ "$NEED_SUDO" == true || ! -t 0 ]]; then
  TMP_SELF=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/phraselock/PhraseLock-Bridge/main/install.sh" -o "$TMP_SELF"
  chmod +x "$TMP_SELF"
  # < /dev/tty matters here, not just cosmetic: without it, stdin stays
  # whatever it was before (the now-drained curl pipe, if piped), so this
  # guard would keep re-triggering on every re-exec, looping forever. Safe
  # to redirect now because bash reads the script from the file argument
  # this time, not from stdin — freeing stdin up for the terminal (and for
  # sudo's own password prompt, which wants one too).
  if [[ "$NEED_SUDO" == true ]]; then
    exec sudo bash "$TMP_SELF" "$@" < /dev/tty
  else
    exec bash "$TMP_SELF" "$@" < /dev/tty
  fi
fi

GITHUB_REPO="phraselock/PhraseLock-Bridge"
VALID_COMPONENTS="PLPServer PLPProxyServer PLPProxyClient"

# Root is guaranteed by this point — either we already were, or the guard
# above re-exec'd us through sudo (or exited with a clear error if sudo
# wasn't available).

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
