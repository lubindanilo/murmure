#!/usr/bin/env bash
# Construit build/Murmure.app à partir du package Swift.
# Usage : Scripts/build-app.sh [debug|release]   (release par défaut)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Murmure.app"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
# Identité de signature : "-" (ad hoc) par défaut, ou "Developer ID Application: …" pour distribuer.
SIGN_ID="${MURMURE_SIGN_IDENTITY:--}"

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Murmure" "$APP/Contents/MacOS/Murmure"

# Framework llama.cpp (dynamique) et bundles de ressources des dépendances.
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Murmure" 2>/dev/null || true

[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Murmure</string>
  <key>CFBundleDisplayName</key><string>Murmure</string>
  <key>CFBundleIdentifier</key><string>app.murmure.Murmure</string>
  <key>CFBundleExecutable</key><string>Murmure</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Murmure écoute votre voix pendant que vous maintenez la touche de dictée.</string>
  <key>NSAppleEventsUsageDescription</key><string>Murmure lit l'adresse de l'onglet actif pour activer le mode associé à un site.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>app.murmure.Murmure</string>
    <key>CFBundleURLSchemes</key><array><string>murmure</string></array>
  </dict></array>
  <key>NSSpeechRecognitionUsageDescription</key><string>Murmure utilise la reconnaissance vocale d'Apple si vous choisissez ce modèle.</string>
</dict>
</plist>
PLIST

# Signature : runtime durci + entitlements (micro, réseau) pour la notarisation.
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
  --entitlements "$ROOT/Resources/Murmure.entitlements" "$APP"

echo "OK : $APP"
