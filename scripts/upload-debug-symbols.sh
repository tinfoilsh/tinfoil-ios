#!/bin/bash
#
# Uploads an archive's debug symbols and sources to Sentry. Without them a
# report from that build names none of the app's functions. Xcode runs this
# as it makes an archive.

set -euo pipefail

REPORTING_BUNDLE_IDENTIFIER="sh.tinfoil.TinfoilChat"
SENTRY_ORGANIZATION="tinfoil"
SENTRY_PROJECT_SLUG="mobile-ios"
CLI_INSTALL_URL="https://cli.sentry.dev"

# A build under another identifier sends no reports, so it has nothing to
# upload symbols for.
if [ "${PRODUCT_BUNDLE_IDENTIFIER:-}" != "$REPORTING_BUNDLE_IDENTIFIER" ]; then
  echo "note: debug symbols are uploaded only for $REPORTING_BUNDLE_IDENTIFIER"
  exit 0
fi

# Xcode runs scripts with a short PATH that leaves out where the CLI installs.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v sentry >/dev/null; then
  echo "error: the Sentry CLI is not installed, so reports from this archive would name none of its functions. Install it from $CLI_INSTALL_URL and run 'sentry auth login'."
  exit 1
fi

export SENTRY_ORG="$SENTRY_ORGANIZATION"
export SENTRY_PROJECT="$SENTRY_PROJECT_SLUG"

if ! sentry debug-files upload --include-sources "$DWARF_DSYM_FOLDER_PATH"; then
  echo "error: the debug symbols could not be uploaded to Sentry, so reports from this archive would name none of its functions."
  exit 1
fi

if [ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
  touch "$SCRIPT_OUTPUT_FILE_0"
fi
