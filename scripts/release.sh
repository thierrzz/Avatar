#!/usr/bin/env bash
#
# release.sh — Build, sign, notarize en publiceer een Avatar release.
#
# Gebruik:
#   ./scripts/release.sh 1.1 2
#   (MARKETING_VERSION=1.1, CURRENT_PROJECT_VERSION=2)
#
# Vereisten:
#   - Xcode command-line tools
#   - xcodegen (brew install xcodegen)
#   - gh CLI (brew install gh), ingelogd
#   - Sparkle's sign_update tool (zie stap 0)
#   - Apple Developer ID certificate in Keychain
#   - App-specific password voor notarytool: opgeslagen als Keychain profiel "AC_PASSWORD"
#     (xcrun notarytool store-credentials "AC_PASSWORD" ...)
#
set -euo pipefail

VERSION="${1:?Gebruik: release.sh <versie> <build>  (bv. release.sh 1.1 2)}"
BUILD="${2:?Gebruik: release.sh <versie> <build>  (bv. release.sh 1.1 2)}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Avatar.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ZIP_NAME="Avatar-${VERSION}.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
SCHEME="Avatar"

# Sparkle sign_update — zoek in DerivedData of stel SIGN_UPDATE_PATH in
SIGN_UPDATE="${SIGN_UPDATE_PATH:-$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1)}"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "❌ sign_update niet gevonden. Stel SIGN_UPDATE_PATH in of bouw het project eerst in Xcode."
  exit 1
fi

echo "📦 Release Avatar v${VERSION} (build ${BUILD})"

# 1. Versie bumpen in project.yml
echo "→ Versie bumpen in project.yml..."
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"${VERSION}\"/" "$PROJECT_DIR/project.yml"
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"${BUILD}\"/" "$PROJECT_DIR/project.yml"

# 2. Xcode project regenereren
echo "→ xcodegen generate..."
cd "$PROJECT_DIR"
xcodegen generate

# 3. Archiveren
echo "→ Archiveren..."
rm -rf "$BUILD_DIR"
xcodebuild \
  -project Avatar.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive

# 4. Exporteren
echo "→ Exporteren..."
# Maak een minimale export-opties plist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

# 5. Zippen
echo "→ Zippen..."
cd "$EXPORT_DIR"
ditto -c -k --keepParent Avatar.app "$ZIP_PATH"

# 6. Notariseren
echo "→ Notariseren..."
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "AC_PASSWORD" \
  --wait

# 7. Staple (op de .app, niet de zip)
echo "→ Stapling..."
xcrun stapler staple "$EXPORT_DIR/Avatar.app"

# Na staple opnieuw zippen (zodat de zip de gestapled app bevat)
rm -f "$ZIP_PATH"
cd "$EXPORT_DIR"
ditto -c -k --keepParent Avatar.app "$ZIP_PATH"

# 8. EdDSA signatuur
echo "→ EdDSA signeren..."
SIGNATURE_OUTPUT=$("$SIGN_UPDATE" "$ZIP_PATH")
echo "   $SIGNATURE_OUTPUT"

# Parse edSignature en length
ED_SIGNATURE=$(echo "$SIGNATURE_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(stat -f%z "$ZIP_PATH")

# 9. Appcast updaten
echo "→ Appcast updaten..."
PUBDATE=$(date -R)
NEW_ITEM=$(cat <<ITEM
    <item>
      <title>Versie ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/thierrzz/Avatar/releases/download/v${VERSION}/${ZIP_NAME}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
ITEM
)

# Voeg het nieuwe item in na <channel> (voor bestaande items)
cd "$PROJECT_DIR"
sed -i '' "/<channel>/a\\
${NEW_ITEM}
" appcast.xml

# 10. GitHub Release
echo "→ GitHub Release aanmaken..."
gh release create "v${VERSION}" "$ZIP_PATH" \
  --title "Avatar v${VERSION}" \
  --generate-notes

echo ""
echo "✅ Release v${VERSION} gepubliceerd!"
echo ""
echo "Vergeet niet:"
echo "  1. Controleer appcast.xml en commit+push"
