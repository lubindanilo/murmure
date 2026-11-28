#!/bin/bash
# Installe (ou met à jour) Ramage dans /Applications.
#   curl -fsSL https://ramage-ai.com/install.sh | bash
# Ramage s'appelait Murmure : une ancienne copie Murmure.app (même identifiant) est remplacée.
set -euo pipefail

URL="https://github.com/lubindanilo/murmure-releases/releases/latest/download/Ramage.zip"
APP_NAME="Ramage.app"
LEGACY_NAME="Murmure.app"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Ramage fonctionne sur Mac uniquement."
[ "$(uname -m)" = "arm64" ] || fail "Ramage demande un Mac avec puce Apple (M1 ou plus récent)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "Ramage demande macOS 15 Sequoia ou plus récent (vous avez $(sw_vers -productVersion))."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Téléchargement de Ramage…"
if ! curl -fL --progress-bar "$URL" -o "$tmp/Ramage.zip"; then
  # Release publiée avant le changement de nom : l'archive s'appelle encore Murmure.zip.
  curl -fL --progress-bar "${URL%/Ramage.zip}/Murmure.zip" -o "$tmp/Ramage.zip" || fail "Téléchargement impossible. Vérifiez votre connexion et réessayez."
  APP_NAME="Murmure.app"
fi
ditto -x -k "$tmp/Ramage.zip" "$tmp" || fail "Archive illisible. Réessayez dans un instant."
[ -d "${tmp}/${APP_NAME}" ] || fail "Archive incomplète. Réessayez dans un instant."

dest="/Applications"
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"

if pgrep -x "Ramage|Murmure" >/dev/null 2>&1; then
  osascript -e 'tell application id "app.murmure.Murmure" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "Ramage|Murmure" >/dev/null 2>&1 || break; sleep 0.5; done
  pkill -x Ramage 2>/dev/null || true
  pkill -x Murmure 2>/dev/null || true
fi

say "Installation dans ${dest}…"
rm -rf "${dest}/${APP_NAME}"
# Seulement notre ancienne app (même identifiant), jamais une autre app nommée Murmure.
for old in "/Applications/${LEGACY_NAME}" "$HOME/Applications/${LEGACY_NAME}"; do
  if [ -d "$old" ] && [ "$(defaults read "$old/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)" = "app.murmure.Murmure" ]; then
    rm -rf "$old"
  fi
done
ditto "${tmp}/${APP_NAME}" "${dest}/${APP_NAME}"
xattr -dr com.apple.quarantine "${dest}/${APP_NAME}" 2>/dev/null || true

open "${dest}/${APP_NAME}"
if [ -n "${MURMURE_UPDATE:-}${RAMAGE_UPDATE:-}" ]; then
  say "Ramage est à jour."
else
  say "C'est prêt. Ramage s'ouvre : suivez les quelques étapes à l'écran."
fi
