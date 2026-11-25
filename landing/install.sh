#!/bin/bash
# Installe (ou met à jour) Murmure dans /Applications.
#   curl -fsSL https://murmure-mac.vercel.app/install.sh | bash
set -euo pipefail

URL="https://github.com/lubindanilo/murmure-releases/releases/latest/download/Murmure.zip"
APP_NAME="Murmure.app"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Murmure fonctionne sur Mac uniquement."
[ "$(uname -m)" = "arm64" ] || fail "Murmure demande un Mac avec puce Apple (M1 ou plus récent)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "Murmure demande macOS 15 Sequoia ou plus récent (vous avez $(sw_vers -productVersion))."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Téléchargement de Murmure…"
curl -fL --progress-bar "$URL" -o "$tmp/Murmure.zip" || fail "Téléchargement impossible. Vérifiez votre connexion et réessayez."
ditto -x -k "$tmp/Murmure.zip" "$tmp" || fail "Archive illisible. Réessayez dans un instant."
[ -d "${tmp}/${APP_NAME}" ] || fail "Archive incomplète. Réessayez dans un instant."

dest="/Applications"
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"

if pgrep -x Murmure >/dev/null 2>&1; then
  osascript -e 'tell application "Murmure" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Murmure >/dev/null 2>&1 || break; sleep 0.5; done
  pkill -x Murmure 2>/dev/null || true
fi

say "Installation dans ${dest}…"
rm -rf "${dest}/${APP_NAME}"
ditto "${tmp}/${APP_NAME}" "${dest}/${APP_NAME}"
xattr -dr com.apple.quarantine "${dest}/${APP_NAME}" 2>/dev/null || true

open "${dest}/${APP_NAME}"
if [ -n "${MURMURE_UPDATE:-}" ]; then
  say "Murmure est à jour."
else
  say "C'est prêt. Murmure s'ouvre : suivez les quelques étapes à l'écran."
fi
