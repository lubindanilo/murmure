#!/usr/bin/env bash
# Publie la dernière compilation réussie de main : release sur lubindanilo/murmure-releases
# (binaires publics), puis landing/version.json mis à jour (le site redéploie tout seul).
# Usage : Scripts/publish-release.sh [run-id]
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=lubindanilo/murmure
PUB=lubindanilo/murmure-releases
VERSION=$(cat VERSION)

run=${1:-$(gh run list -R "$REPO" -w build.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId')}
[ -n "$run" ] || { echo "Aucune compilation réussie" >&2; exit 1; }
sha=$(gh run view "$run" -R "$REPO" --json headSha -q .headSha)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
gh run download "$run" -R "$REPO" -D "$work"
zip=$(find "$work" -name Murmure.zip | head -1)
dir=$(dirname "${zip:-$work/none}")
[ -f "$dir/Murmure.zip" ] && [ -f "$dir/Murmure.dmg" ] || { echo "Artefacts manquants" >&2; exit 1; }

tag="v$VERSION"
notes="Murmure $VERSION (${sha:0:7})"
if gh release view "$tag" -R "$PUB" >/dev/null 2>&1; then
  gh release upload "$tag" "$dir/Murmure.zip" "$dir/Murmure.dmg" -R "$PUB" --clobber
else
  gh release create "$tag" "$dir/Murmure.zip" "$dir/Murmure.dmg" -R "$PUB" --title "Murmure $VERSION" --notes "$notes" --latest
fi

printf '{\n  "version": "%s",\n  "published": "%s"\n}\n' "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > landing/version.json
if ! git diff --quiet landing/version.json 2>/dev/null || ! git ls-files --error-unmatch landing/version.json >/dev/null 2>&1; then
  git add landing/version.json
  git commit -qm "Publier Murmure $VERSION"
  git push -q
fi
echo "Publié : https://github.com/$PUB/releases/tag/$tag"
