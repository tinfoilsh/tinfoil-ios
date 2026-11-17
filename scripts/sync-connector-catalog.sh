#!/usr/bin/env bash
# Copies the web app's catalog of connectors into the app, which lists the
# same servers.
# Usage: scripts/sync-connector-catalog.sh [web app checkout]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
webapp="$(cd "${1:-$root/../tinfoil-webapp}" && pwd)"
catalog="src/constants/connector-catalog.json"

# The copy is of a commit, so the web app's catalog must be as committed.
if [[ -n "$(git -C "$webapp" status --porcelain --untracked-files=all --ignored -- "$catalog")" ]]; then
  echo "$webapp/$catalog has changes not committed" >&2
  exit 1
fi

cp "$webapp/$catalog" "$root/TinfoilChat/Resources/connector-catalog.json"
echo "Synced the connector catalog at $(git -C "$webapp" rev-parse HEAD)"
