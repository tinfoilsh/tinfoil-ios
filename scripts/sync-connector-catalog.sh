#!/usr/bin/env bash
# Copies the web app's catalog of connectors into the app, which lists the
# same servers.
# Usage: scripts/sync-connector-catalog.sh [web app checkout]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
webapp="$(cd "${1:-$root/../tinfoil-webapp}" && pwd)"
cp "$webapp/src/constants/connector-catalog.json" "$root/TinfoilChat/Resources/connector-catalog.json"
echo "Synced the connector catalog from $webapp"
