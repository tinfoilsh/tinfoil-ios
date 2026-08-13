#!/usr/bin/env bash
set -euo pipefail

project_file="TinfoilChat.xcodeproj/project.pbxproj"
shared_scheme="TinfoilChat.xcodeproj/xcshareddata/xcschemes/TinfoilChat.xcscheme"

marketing_versions=$(sed -nE 's/^[[:space:]]*TINFOIL_MARKETING_VERSION = ([^;]+);/\1/p' "$project_file")
build_numbers=$(sed -nE 's/^[[:space:]]*TINFOIL_BUILD_NUMBER = ([^;]+);/\1/p' "$project_file")
marketing_count=$(printf '%s\n' "$marketing_versions" | sed '/^$/d' | wc -l | tr -d ' ')
build_count=$(printf '%s\n' "$build_numbers" | sed '/^$/d' | wc -l | tr -d ' ')
marketing_version=$(printf '%s\n' "$marketing_versions" | sed -n '1p')
build_number=$(printf '%s\n' "$build_numbers" | sed -n '1p')

if [[ "$marketing_count" -ne 2 ]] || [[ $(printf '%s\n' "$marketing_versions" | sort -u | wc -l | tr -d ' ') -ne 1 ]]; then
  echo "App Debug and Release must define one matching TINFOIL_MARKETING_VERSION." >&2
  exit 1
fi

if [[ "$build_count" -ne 2 ]] || [[ $(printf '%s\n' "$build_numbers" | sort -u | wc -l | tr -d ' ') -ne 1 ]]; then
  echo "App Debug and Release must define one matching TINFOIL_BUILD_NUMBER." >&2
  exit 1
fi

marketing_references=$(grep -F -c 'MARKETING_VERSION = "$(TINFOIL_MARKETING_VERSION)";' "$project_file")
build_references=$(grep -F -c 'CURRENT_PROJECT_VERSION = "$(TINFOIL_BUILD_NUMBER)";' "$project_file")

if [[ "$marketing_references" -ne 4 || "$build_references" -ne 4 ]]; then
  echo "The app and share extension must inherit version and build settings in Debug and Release." >&2
  exit 1
fi

if [[ ! -f "$shared_scheme" ]] || ! grep -F -q 'BlueprintName = "TinfoilChat"' "$shared_scheme"; then
  echo "The shared TinfoilChat app scheme is missing or invalid." >&2
  exit 1
fi

release_ref="${1:-}"
if [[ "$release_ref" == v* ]]; then
  release_version="${release_ref#v}"
  if [[ "$release_version" != "$marketing_version" ]]; then
    echo "Release tag $release_ref does not match app version $marketing_version." >&2
    exit 1
  fi
fi

echo "Release settings are consistent: $marketing_version ($build_number)."
