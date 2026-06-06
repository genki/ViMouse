#!/usr/bin/env bash

set -euo pipefail

IDENTITY_LABEL=${IDENTITY_LABEL:-}
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"

if ! command -v security >/dev/null 2>&1; then
  echo "error: 'security' command not found. Run on macOS with Xcode command line tools installed." >&2
  exit 1
fi

if [[ -z "${IDENTITY_LABEL}" ]]; then
  echo "error: set IDENTITY_LABEL to the exact signing identity label to grant CLI access." >&2
  echo "hint: security find-identity -v -p codesigning" >&2
  exit 1
fi

IDENTITY_LOOKUP=$(security find-identity -v -p codesigning -s "$IDENTITY_LABEL" 2>/dev/null || true)
IDENTITY_HASH=$(echo "$IDENTITY_LOOKUP" | awk 'NR==2 {print $2}')

if [[ -z "${IDENTITY_HASH}" ]]; then
  echo "error: signing identity '${IDENTITY_LABEL}' not found. Verify the certificate is installed in the login keychain." >&2
  exit 1
fi

read -rsp "Enter macOS login password (for keychain '${KEYCHAIN_PATH}'): " KEYCHAIN_PWD
echo

if ! security unlock-keychain -p "${KEYCHAIN_PWD}" "${KEYCHAIN_PATH}"; then
  unset KEYCHAIN_PWD
  echo "error: failed to unlock keychain '${KEYCHAIN_PATH}'." >&2
  exit 1
fi

if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PWD}" -a "${IDENTITY_HASH}" "${KEYCHAIN_PATH}" 2>/dev/null; then
  echo "warning: targeted key partition update failed; applying to entire keychain scope..." >&2
  if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PWD}" "${KEYCHAIN_PATH}"; then
    unset KEYCHAIN_PWD
    echo "error: failed to update key partition list for identity '${IDENTITY_LABEL}'." >&2
    exit 1
  fi
fi

unset KEYCHAIN_PWD

echo "Successfully granted CLI access for '${IDENTITY_LABEL}' (hash: ${IDENTITY_HASH})."
