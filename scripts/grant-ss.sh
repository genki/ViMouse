#!/usr/bin/env bash

set -euo pipefail

KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

if [[ $EUID -ne 0 ]]; then
  echo "error: screen sharing setup requires administrator privileges. Re-run with sudo."
  exit 1
fi

if [[ ! -x "${KICKSTART}" ]]; then
  echo "error: kickstart utility not found at ${KICKSTART}. This script targets macOS."
  exit 1
fi

"${KICKSTART}" -activate -configure -access -on -privs -all -allowAccessFor -allUsers -restart -agent >/dev/null

echo "Screen Sharing (Remote Management) has been enabled for all local users."
