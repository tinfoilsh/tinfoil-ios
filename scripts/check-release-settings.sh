#!/usr/bin/env bash
set -euo pipefail

project_file="${PROJECT_FILE:-TinfoilChat.xcodeproj/project.pbxproj}"
shared_scheme="${SHARED_SCHEME:-TinfoilChat.xcodeproj/xcshareddata/xcschemes/TinfoilChat.xcscheme}"

configuration_block() {
  local configuration_id="$1"
  awk -v configuration_id="$configuration_id" '
    $0 ~ "^[[:space:]]*" configuration_id " /\\*" { in_configuration = 1 }
    in_configuration { print }
    in_configuration && /^[[:space:]]*name = (Debug|Release);/ { exit }
  ' "$project_file"
}

assert_setting() {
  local configuration_id="$1"
  local setting="$2"
  local expected="$3"
  local lines
  local count
  local normalized

  lines=$(configuration_block "$configuration_id" | grep -E "^[[:space:]]*\"?${setting}(\\[[^]]+\\])?\"?[[:space:]]*=" || true)
  count=$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ')
  normalized=$(printf '%s\n' "$lines" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  if [[ "$count" -ne 1 || "$normalized" != "$expected" ]]; then
    echo "Configuration $configuration_id must define exactly: $expected" >&2
    exit 1
  fi
}

configuration_id() {
  local owner="$1"
  local configuration="$2"
  awk -v owner="$owner" -v configuration="$configuration" '
    index($0, "Build configuration list for " owner) && / \*\/ = \{/ {
      in_owner = 1
      next
    }
    in_owner && /buildConfigurations = \(/ {
      in_configurations = 1
      next
    }
    in_configurations && index($0, "/* " configuration " */") {
      print $1
      exit
    }
    in_configurations && /\);/ { exit }
  ' "$project_file"
}

project_debug=$(configuration_id 'PBXProject "TinfoilChat"' Debug)
project_release=$(configuration_id 'PBXProject "TinfoilChat"' Release)
extension_debug=$(configuration_id 'PBXNativeTarget "TinfoilShareExtension"' Debug)
extension_release=$(configuration_id 'PBXNativeTarget "TinfoilShareExtension"' Release)
app_debug=$(configuration_id 'PBXNativeTarget "TinfoilChat"' Debug)
app_release=$(configuration_id 'PBXNativeTarget "TinfoilChat"' Release)

for configuration_id in "$project_debug" "$project_release" "$extension_debug" "$extension_release" "$app_debug" "$app_release"; do
  if [[ -z "$configuration_id" ]]; then
    echo "Could not derive all required Xcode configuration IDs." >&2
    exit 1
  fi
done

marketing_version=$(configuration_block "$project_debug" | sed -nE 's/^[[:space:]]*TINFOIL_MARKETING_VERSION = ([^;]+);/\1/p')
build_number=$(configuration_block "$project_debug" | sed -nE 's/^[[:space:]]*TINFOIL_BUILD_NUMBER = ([^;]+);/\1/p')

if [[ -z "$marketing_version" || -z "$build_number" ]]; then
  echo "Project release settings are missing." >&2
  exit 1
fi

for configuration_id in "$project_debug" "$project_release"; do
  assert_setting "$configuration_id" TINFOIL_MARKETING_VERSION "TINFOIL_MARKETING_VERSION = $marketing_version;"
  assert_setting "$configuration_id" TINFOIL_BUILD_NUMBER "TINFOIL_BUILD_NUMBER = $build_number;"
done

for configuration_id in "$extension_debug" "$extension_release" "$app_debug" "$app_release"; do
  assert_setting "$configuration_id" MARKETING_VERSION 'MARKETING_VERSION = "$(TINFOIL_MARKETING_VERSION)";'
  assert_setting "$configuration_id" CURRENT_PROJECT_VERSION 'CURRENT_PROJECT_VERSION = "$(TINFOIL_BUILD_NUMBER)";'
done

if [[ ! -f "$shared_scheme" ]] || ! grep -F -q 'BlueprintName = "TinfoilChat"' "$shared_scheme"; then
  echo "The shared TinfoilChat app scheme is missing or invalid." >&2
  exit 1
fi

release_ref="${1:-}"
if [[ "$release_ref" == v* ]]; then
  release_version="${release_ref#v}"
  release_base_version="${release_version%%-*}"
  if [[ "$release_base_version" != "$marketing_version" ]]; then
    echo "Release tag $release_ref does not match app version $marketing_version." >&2
    exit 1
  fi
fi

echo "Release settings are consistent: $marketing_version ($build_number)."
