#!/usr/bin/env bash
# Construit Murmure et l'installe sur CE Mac (/Applications), sans rien publier.
# Signature stable avec le certificat auto-signé de Murmure : l'autorisation Accessibilité
# tient d'une installation à l'autre.
#
# Prérequis (une fois) : les fichiers locaux ~/.config/murmure/{murmure.p12,p12-password,keychain-password}
# et le trousseau ~/Library/Keychains/murmure-signing.keychain-db
# où murmure.p12 est importé (security create-keychain / import / set-key-partition-list).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$HOME/.config/murmure"
KC="$HOME/Library/Keychains/murmure-signing.keychain-db"
DEST="/Applications/Murmure.app"

if [ -f "$KC" ] && [ -f "$CONF/keychain-password" ]; then
  security unlock-keychain -p "$(cat "$CONF/keychain-password")" "$KC"
  SHA="$(security find-identity -p codesigning "$KC" | awk '/"Murmure"/ {print $2; exit}')"
  export MURMURE_SIGN_IDENTITY="$SHA" MURMURE_KEYCHAIN="$KC"
else
  echo "Certificat Murmure absent : signature ad hoc (l'autorisation Accessibilité sautera)." >&2
fi

"$ROOT/Scripts/build-app.sh" "${1:-release}"

# Quitter l'app en cours, remplacer, relancer.
osascript -e 'tell application id "app.murmure.Murmure" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Murmure >/dev/null || break; sleep 0.3; done
pkill -x Murmure 2>/dev/null || true
rm -rf "$DEST"
ditto "$ROOT/build/Murmure.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"
echo "Installé : $DEST ($(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString))"
