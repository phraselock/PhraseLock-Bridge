#!/bin/bash
set -euo pipefail

# Builds the three tar.gz packages via build-tars.sh and publishes them as
# a new GitHub release on phraselock/PhraseLock-Bridge — tags the current
# commit, pushes the tag, uploads the three tarballs as release assets,
# then removes the local tarball files (they're not tracked in git; the
# release is the copy of record).
#
# Usage: ./uploadRelease.sh <version> ["release notes"]
#   <version>        required, e.g. "0.1.2" — becomes tag "v<version>"
#   ["release notes"] optional, defaults to a generic note

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO="phraselock/PhraseLock-Bridge"

if [[ $# -lt 1 || -z "$1" ]]; then
  echo "Usage: ./uploadRelease.sh <version> [\"release notes\"]" >&2
  echo 'Example: ./uploadRelease.sh 0.1.2 "Bugfix release"' >&2
  exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
NOTES="${2:-Release ${TAG}.}"

command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: gh is not authenticated (run 'gh auth login')." >&2; exit 1; }

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag ${TAG} already exists locally — pick a different version or delete it first." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Warning: working tree has uncommitted changes — the release is built from what's" >&2
  echo "on disk now, but the tag will point at the current commit, not these changes." >&2
fi

./build-tars.sh "$VERSION"

TARBALLS=(PLPServer-"${VERSION}".tar.gz PLPProxyServer-"${VERSION}".tar.gz PLPProxyClient-"${VERSION}".tar.gz)

git tag "$TAG"
git push origin "$TAG"

gh release create "$TAG" "${TARBALLS[@]}" --repo "$REPO" --title "$TAG" --notes "$NOTES"

rm -f "${TARBALLS[@]}"

echo "Done: https://github.com/${REPO}/releases/tag/${TAG}"
