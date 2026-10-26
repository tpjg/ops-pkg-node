#!/usr/bin/env bash
# Called by .github/workflows/release.yml after both architectures were built, tested and
# attested. Creates release v<node version>-r<n> with the packages and their .sha256 files.
. "$(dirname "$0")/lib.sh"
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"

n=$(gh release list --repo "$GITHUB_REPOSITORY" --limit 1000 --json tagName \
      -q "[.[].tagName | select(startswith(\"v$NODE_VERSION-r\"))] | length")
tag=v$NODE_VERSION-r$((n + 1))

if (( n > 0 )); then
  previous=$WORK/previous-release
  rm -rf "$previous" && mkdir -p "$previous"
  gh release download "v$NODE_VERSION-r$n" --repo "$GITHUB_REPOSITORY" --pattern '*.sha256' --dir "$previous"
  if diff <(cat "$previous"/*.sha256) <(cat "$DIST"/*.sha256) >/dev/null; then
    echo "packages are identical to v$NODE_VERSION-r$n; nothing to release"
    exit 0
  fi
fi

gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
  --title "Node.js $NODE_VERSION ($tag)" --notes-file - "$DIST"/*.tar.gz "$DIST"/*.sha256 <<NOTES
Node.js $NODE_VERSION ops packages for Nanos, built from commit $GITHUB_SHA.

\`\`\`
$(cat "$DIST"/*.sha256)
\`\`\`

Verify and load (see README, "Consuming the package"):
\`\`\`sh
gh release download $tag --repo $GITHUB_REPOSITORY --pattern '*_linux-x64.tar.gz*'
sha256sum -c ${PKG_NAME}_linux-x64.tar.gz.sha256
gh attestation verify ${PKG_NAME}_linux-x64.tar.gz --repo $GITHUB_REPOSITORY
ops pkg add ${PKG_NAME}_linux-x64.tar.gz --name $PKG_NAME --arch amd64
\`\`\`
NOTES
echo "released $tag"
