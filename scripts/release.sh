#!/bin/bash
# Build, package and publish a GitHub release for dbhydrate.
#
#   scripts/release.sh [version]      # default 0.1.0
#
# Produces dist/:
#   dbhydrate          raw CLI binary (ad-hoc signed)
#   DBHydrate.app.zip  zipped app bundle
#   SHA256SUMS         checksums for both artifacts
#
# Tags the release and publishes it with gh. Requires a clean working tree and
# an authenticated gh CLI. Artifacts are built for this machine's architecture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.1.0}"
TAG="v$VERSION"
DIST="$ROOT/dist"
NOTES="$DIST/release-notes.md"
REPO="$(git remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"

command -v gh >/dev/null || { echo "error: gh is required (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated (gh auth login)" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
	echo "error: working tree is not clean; commit or stash first" >&2
	exit 1
fi

ARCH="$(uname -m)"
echo "==> version $VERSION, arch $ARCH, repo $REPO"

echo "==> cleaning dist/"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> building release CLI and app bundle"
DBHYDRATE_VERSION="$VERSION" ./scripts/build.sh

echo "==> staging artifacts"
cp build/bin/dbhydrate "$DIST/dbhydrate"
chmod +x "$DIST/dbhydrate"
codesign --force --sign - --timestamp=none "$DIST/dbhydrate"

# --norsrc/--noextattr: keep AppleDouble ._ resource forks out of the archive.
# Unzipping them into the bundle breaks the code signature seal.
ditto -c -k --keepParent --norsrc --noextattr \
	build/DBHydrate.app "$DIST/DBHydrate.app.zip"

echo "==> smoke test"
"$DIST/dbhydrate" --help >/dev/null

# The zip must restore to a bundle that still satisfies its signature.
VERIFY="$(mktemp -d)"
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "$DIST/DBHydrate.app.zip" "$VERIFY"
codesign --verify --deep "$VERIFY/DBHydrate.app"
echo "    app bundle signature verifies after unzip"

( cd "$DIST" && shasum -a 256 dbhydrate DBHydrate.app.zip > SHA256SUMS )
cat "$DIST/SHA256SUMS"

echo "==> writing release notes"
cat > "$NOTES" <<NOTES
macOS $ARCH build. Requires macOS 13+.

Download, then either:

- **CLI**: put \`dbhydrate\` anywhere, \`chmod +x dbhydrate\`, and run it.
  Binaries downloaded from a browser carry a quarantine attribute, so macOS
  blocks the first launch. Remove it once:

  \`\`\`console
  xattr -d com.apple.quarantine dbhydrate
  \`\`\`

  Or right-click the file in Finder and choose Open.

- **App bundle**: unzip \`DBHydrate.app.zip\` and open \`DBHydrate.app\` from
  Finder (same first-launch prompt: right-click, then Open).

This release is ad-hoc signed, not notarized with an Apple Developer ID.
The tool needs Full Disk Access for your Dropbox folder and network access.

Checksums (\`SHA256SUMS\`):

\`\`\`
$(cat "$DIST/SHA256SUMS")
\`\`\`
NOTES

echo "==> tagging $TAG"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	echo "    tag $TAG already exists; reusing it"
else
	git tag -a "$TAG" -m "dbhydrate $VERSION"
fi
git push origin "$TAG"

echo "==> publishing GitHub release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
	echo "    release $TAG exists; replacing its assets"
	gh release upload "$TAG" --repo "$REPO" --clobber \
		"$DIST/dbhydrate" "$DIST/DBHydrate.app.zip" "$DIST/SHA256SUMS"
	gh release edit "$TAG" --repo "$REPO" --title "dbhydrate $VERSION" --notes-file "$NOTES"
else
	gh release create "$TAG" \
		--repo "$REPO" \
		--target main \
		--title "dbhydrate $VERSION" \
		--notes-file "$NOTES" \
		"$DIST/dbhydrate" "$DIST/DBHydrate.app.zip" "$DIST/SHA256SUMS"
fi

echo
echo "released: $REPO/releases/tag/$TAG"
gh release view "$TAG" --repo "$REPO"