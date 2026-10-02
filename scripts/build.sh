#!/bin/bash
# Build the release CLI and ad-hoc signed app bundle under build/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.dbhydrate.DBHydrate"
APP="$ROOT/build/DBHydrate.app"

echo "==> swift build -c release --product dbhydrate"
swift build -c release --product dbhydrate

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/dbhydrate" "$APP/Contents/MacOS/DBHydrate"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>          <string>en</string>
	<key>CFBundleExecutable</key>                 <string>DBHydrate</string>
	<key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
	<key>CFBundleName</key>                       <string>DBHydrate</string>
	<key>CFBundlePackageType</key>                <string>APPL</string>
	<key>CFBundleShortVersionString</key>         <string>0.1.0</string>
	<key>CFBundleVersion</key>                    <string>1</string>
	<key>LSMinimumSystemVersion</key>             <string>13.0</string>

	<!-- Agent app: never appears in the Dock, never opens a window, never takes
	     focus. Recall is driven entirely by NSFileCoordinator. -->
	<key>LSUIElement</key>                        <true/>

	<!-- Registered as a document handler so LaunchServices accepts it if the
	     bundle is ever opened with files. LSHandlerRank None means it cannot
	     displace any of the user's existing default applications. -->
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>     <string>Data</string>
			<key>CFBundleTypeRole</key>     <string>Viewer</string>
			<key>LSHandlerRank</key>        <string>None</string>
			<key>LSItemContentTypes</key>
			<array><string>public.data</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

mkdir -p "$ROOT/build/bin"
ln -sf "$APP/Contents/MacOS/DBHydrate" "$ROOT/build/bin/dbhydrate"

echo
echo "built:"
echo "  $ROOT/build/bin/dbhydrate"
echo "  $APP"
echo
echo "try it:"
echo "  $ROOT/build/bin/dbhydrate --dry-run ~/Dropbox/project"
