#!/usr/bin/env bash
# Called by .github/workflows/update-node.yml. If nodejs.org lists a newer Node 24 LTS than
# NODE_VERSION, builds both architectures, records package/expected.sha256, pushes branch
# update-node/<version>, opens a PR and dispatches ci.yml on that branch.
. "$(dirname "$0")/lib.sh"
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"

latest=$("$ROOT/scripts/latest-node.sh")
[[ $latest =~ ^24\.[0-9]+\.[0-9]+$ ]] || die "unexpected version from index.json: '$latest'"
if [[ $(printf '%s\n' "$NODE_VERSION" "$latest" | sort -V | tail -1) == "$NODE_VERSION" ]]; then
  echo "NODE_VERSION $NODE_VERSION is current (newest 24.x LTS: $latest)"
  exit 0
fi
branch=update-node/$latest
if git ls-remote --exit-code "https://github.com/$GITHUB_REPOSITORY.git" "refs/heads/$branch" >/dev/null; then
  echo "branch $branch already exists"
  exit 0
fi

echo "$latest" > "$ROOT/NODE_VERSION"
"$ROOT/scripts/build.sh" x64
"$ROOT/scripts/build.sh" arm64
cat "$DIST"/*.sha256 > "$ROOT/package/expected.sha256"

security=$("$ROOT/scripts/latest-node.sh" --security)
git -C "$ROOT" config user.name "github-actions[bot]"
git -C "$ROOT" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$ROOT" checkout -b "$branch"
git -C "$ROOT" commit -m "⬆️ Node.js $latest" -- NODE_VERSION package/expected.sha256
git -C "$ROOT" push "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git" "$branch"

gh pr create --repo "$GITHUB_REPOSITORY" --head "$branch" --title "⬆️ Node.js $latest" --body-file - <<BODY
Bumps NODE_VERSION from $NODE_VERSION to $latest.

- Release notes: https://github.com/nodejs/node/releases/tag/v$latest
- Security release: $security
- package/expected.sha256, from a build on the update-node runner:
\`\`\`
$(cat "$ROOT/package/expected.sha256")
\`\`\`

CI was dispatched on this branch; its checks run the build on native runners, compare the
result with these checksums and run the acceptance tests. Merging releases the package.
BODY
gh workflow run ci.yml --repo "$GITHUB_REPOSITORY" --ref "$branch"
