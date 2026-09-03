#!/usr/bin/env bash
# Build xml-macker via SwiftPM and wrap the resulting executable in a
# minimal .app bundle so it can be launched like any Mac app.
#
# Usage: ./build-app.sh [release|debug]    (default: release)

set -euo pipefail

MODE="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> swift build ($MODE)"
if [[ "$MODE" == "release" ]]; then
  swift build -c release
  BUILD_DIR="$(swift build -c release --show-bin-path)"
else
  swift build
  BUILD_DIR="$(swift build --show-bin-path)"
fi

BIN="$BUILD_DIR/XMLMacker"
if [[ ! -x "$BIN" ]]; then
  echo "!! build failed: no binary at $BIN" >&2
  exit 1
fi

APP="$ROOT/dist/xml-macker.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/xml-macker"
cp "$ROOT/Resources/xml-macker.icns" "$APP/Contents/Resources/xml-macker.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>xml-macker</string>
  <key>CFBundleIdentifier</key><string>com.ahmed.xmlmacker</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>xml-macker</string>
  <key>CFBundleDisplayName</key><string>xml-macker</string>
  <key>CFBundleIconFile</key><string>xml-macker.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>18</string>
  <!--
    xml-macker edits existing, public formats; it does not own a proprietary
    document format.  Use the system UTIs where they exist and import (never
    export) the two vendor-defined XML formats below.  Alternate rank makes
    xml-macker available in Finder's Open With menu without replacing the
    user's preferred editor/viewer.
  -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>XML Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.xml</string>
        <string>public.svg-image</string>
        <string>public.rss</string>
        <string>public.xhtml</string>
        <string>com.apple.xml-property-list</string>
        <string>com.topografix.gpx</string>
        <string>com.google.earth.kml</string>
      </array>
    </dict>
    <!--
      Several standards have no stable system UTI on a clean macOS install.
      A separate extension-based declaration lets Finder offer xml-macker for
      those files without inventing an exported UTI that the app does not own.
    -->
    <dict>
      <key>CFBundleTypeName</key><string>XML-Based Text Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>xsd</string>
        <string>xsl</string>
        <string>xslt</string>
        <string>wsdl</string>
        <string>atom</string>
        <string>opf</string>
        <string>ncx</string>
        <string>mathml</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.topografix.gpx</string>
      <key>UTTypeDescription</key><string>GPS Exchange Format (GPX)</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.xml</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><string>gpx</string>
        <key>public.mime-type</key><string>application/gpx+xml</string>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.google.earth.kml</string>
      <key>UTTypeDescription</key><string>Keyhole Markup Language (KML)</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.xml</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><string>kml</string>
        <key>public.mime-type</key><string>application/vnd.google-earth.kml+xml</string>
      </dict>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Validate the generated bundle and ad-hoc sign it for local development.
# Ad-hoc signing is deliberately not presented as distribution notarization.
plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> done: $APP"
