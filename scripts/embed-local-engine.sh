#!/bin/bash
set -euo pipefail
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SDK_ARCHIVE="${VIMOUSE_LOCAL_SDK_ARCHIVE:-${PROJECT_DIR}/LocalEngine/sdk.tar.gz}"
if [[ ! -f "${SDK_ARCHIVE}" ]]; then
  SDK_ARCHIVE="${PROJECT_DIR}/../vimouse-ambiguous-ime/dist/vimouse-ime-macos-arm64-v2.tar.gz"
fi
EXPECTED=a4cb8d87b7b21357b004a5444c01140d901d81331e2d6fa69a001ef75a5619f0
ACTUAL="$(shasum -a 256 "${SDK_ARCHIVE}" | awk '{print $1}')"
[[ "${ACTUAL}" == "${EXPECTED}" ]] || { echo 'error: local SDK archive hash mismatch' >&2; exit 1; }
SDK_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vimouse-sdk.XXXXXX")"
trap 'rm -rf "${SDK_STAGE}"' EXIT
/usr/bin/tar -xzf "${SDK_ARCHIVE}" -C "${SDK_STAGE}"
SDK="${SDK_STAGE}/vimouse-ime-macos-arm64-v2"
APP_CONTENTS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
mkdir -p "${APP_CONTENTS}/Frameworks" "${APP_CONTENTS}/Resources/LocalConversion"
cp "${SDK}/lib/libvimouse_ime.dylib" "${APP_CONTENTS}/Frameworks/"
cp -R "${SDK}/resources/." "${APP_CONTENTS}/Resources/LocalConversion/"
cp -R "${SDK}/licenses" "${APP_CONTENTS}/Resources/LocalConversion/"
cp "${SDK}/manifest.json" "${SDK}/include/vimouse_ime.h" "${APP_CONTENTS}/Resources/LocalConversion/"
chmod -R a+rX "${APP_CONTENTS}/Resources/LocalConversion"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  # Xcode's controlled signing flags supply the temporary keychain for release builds.
  /usr/bin/codesign --force --sign "${IDENTITY:-'-'}" ${OTHER_CODE_SIGN_FLAGS:-} "${APP_CONTENTS}/Frameworks/libvimouse_ime.dylib"
fi
