#!/usr/bin/env bash
# Copies the harness's protocol and recorded runs into harness-protocol/, and
# writes the Swift types its schemas describe.
# Usage: scripts/sync-harness-protocol.sh [harness checkout]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="$(cd "${1:-$root/../confidential-tinfoil-harness}" && pwd)"
protocol_dir="$root/harness-protocol"
generated_dir="$root/TinfoilChat/Services/Harness/Protocol"
generator_version="1.14.3"
generator_cache="${XDG_CACHE_HOME:-$HOME/Library/Caches}/tinfoil-ios/swift-openapi-generator-$generator_version"
generator="$generator_cache/.build/release/swift-openapi-generator"

# The copy is of the commit it names, so the harness's protocol must be as
# committed.
if [[ -n "$(git -C "$harness" status --porcelain --untracked-files=all --ignored -- protocol)" ]]; then
  echo "$harness/protocol has changes not committed" >&2
  exit 1
fi
revision="$(git -C "$harness" rev-parse HEAD)"

if [[ ! -x "$generator" ]]; then
  rm -rf "$generator_cache"
  git clone --quiet --depth 1 --branch "$generator_version" \
    https://github.com/apple/swift-openapi-generator.git "$generator_cache"
  swift build --configuration release --package-path "$generator_cache" \
    --product swift-openapi-generator
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Only the schemas are generated. The client has its own transport and builds
# its requests itself, so the operations would go unused.
{
  echo "generate:"
  echo "  - types"
  echo "namingStrategy: idiomatic"
  echo "accessModifier: internal"
  echo "filter:"
  echo "  schemas:"
  awk '
    /^  schemas:/ { in_schemas = 1; next }
    in_schemas && /^  [^ ]/ { exit }
    in_schemas && /^    [A-Za-z][A-Za-z0-9_.-]*:/ { sub(/:.*/, ""); sub(/^ +/, ""); print "    - " $0 }
  ' "$harness/protocol/openapi.yaml"
} > "$work/config.yaml"

if ! "$generator" generate --config "$work/config.yaml" --output-directory "$work/out" \
  "$harness/protocol/openapi.yaml" > "$work/generator.log" 2>&1; then
  cat "$work/generator.log" >&2
  exit 1
fi

# Nothing in the checkout is replaced until the whole copy and every
# generated file are written.
header="// Generated from harness-protocol/openapi.yaml by scripts/sync-harness-protocol.sh. Do not edit."
cp -R "$harness/protocol" "$work/protocol"
printf '%s\n' "$revision" > "$work/protocol/revision"
mkdir -p "$work/generated"
{ echo "$header"; cat "$work/out/Types+Components.swift"; } > "$work/generated/Components.swift"
{ echo "$header"; cat "$work/out/Types+Components+Schemas.swift"; } > "$work/generated/Schemas.swift"
rm -rf "$protocol_dir" "$generated_dir"
mv "$work/protocol" "$protocol_dir"
mkdir -p "$(dirname "$generated_dir")"
mv "$work/generated" "$generated_dir"
echo "Synced harness protocol at $revision"
