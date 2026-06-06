#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${PROJECT_DIR}/build/UnitTests}"
CONFIGURATION="${CONFIGURATION:-Debug}"

cd "${PROJECT_DIR}"

xcodebuild \
  -project ViMouse.xcodeproj \
  -target ViMouseTests \
  -configuration "${CONFIGURATION}" \
  build \
  SYMROOT="${BUILD_ROOT}" \
  OBJROOT="${BUILD_ROOT}/Intermediates" \
  CODE_SIGNING_ALLOWED=NO

xcrun xctest "${BUILD_ROOT}/${CONFIGURATION}/ViMouseTests.xctest"
