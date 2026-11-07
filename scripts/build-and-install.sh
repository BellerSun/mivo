#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Mivo.app"
BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" && $# == 1 ]]; then
  BUILD_ONLY=1
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--build-only]" >&2
  exit 1
fi
ICON="$ROOT/.build/icons/Mivo.icns"
SIGN_IDENTITY="${MIVO_SIGNING_IDENTITY:-$(python3 "$ROOT/scripts/signing-config.py" identity)}"
SIGN_KEYCHAIN="${MIVO_SIGNING_KEYCHAIN:-$(python3 "$ROOT/scripts/signing-config.py" keychain)}"
if [[ ! "$SIGN_IDENTITY" =~ '^[[:xdigit:]]{40}$' ]]; then
  echo "MIVO_SIGNING_IDENTITY must be the SHA-1 fingerprint of a persistent signing certificate; ad-hoc signing is disabled." >&2
  exit 1
fi
mkdir -p "$ROOT/.build"
python3 "$ROOT/scripts/generate-icons.py"
BUILD_KEY="$( { cat "$ROOT/Sources/HoldApp.swift" "$ROOT/Info.plist" "$ROOT/scripts/build-and-install.sh" "$ICON"; swiftc --version 2>&1; echo "$SIGN_IDENTITY"; echo "$SIGN_KEYCHAIN"; } | shasum -a 256 | cut -d ' ' -f 1)"
if [[ "$BUILD_ONLY" == "0" && "${MIVO_FORCE_REBUILD:-0}" != "1" && -f "$ROOT/.build/install-source" && -f "$ROOT/.build/install-binary" && -f "$APP/Contents/MacOS/DJIMicHold" ]] \
  && [[ "$(cat "$ROOT/.build/install-source")" == "$BUILD_KEY" ]] \
  && [[ "$(shasum -a 256 "$APP/Contents/MacOS/DJIMicHold" | cut -d ' ' -f 1)" == "$(cat "$ROOT/.build/install-binary")" ]] \
  && cmp -s "$ROOT/Info.plist" "$APP/Contents/Info.plist" \
  && cmp -s "$ICON" "$APP/Contents/Resources/Mivo.icns" \
  && codesign --verify --strict "$APP"; then
  echo "Already installed (unchanged): $APP"
  exit 0
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/mivo-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Mivo.app/Contents/MacOS" "$STAGING/Mivo.app/Contents/Resources"
cp "$ROOT/Info.plist" "$STAGING/Mivo.app/Contents/Info.plist"
cp "$ICON" "$STAGING/Mivo.app/Contents/Resources/Mivo.icns"
swiftc -target "$(/usr/bin/uname -m)-apple-macosx13.0" -parse-as-library -O \
  -framework SwiftUI -framework AppKit -framework ApplicationServices \
  -framework CoreGraphics -framework IOKit \
  -o "$STAGING/Mivo.app/Contents/MacOS/DJIMicHold" \
  "$ROOT/Sources/HoldApp.swift"
codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --timestamp=none "$STAGING/Mivo.app"
codesign --verify --strict "$STAGING/Mivo.app"
codesign --display --extract-certificates="$STAGING/signer-" "$STAGING/Mivo.app"
ACTUAL_SIGNER="$(shasum -a 1 "$STAGING/signer-0" | cut -d ' ' -f 1)"
if [[ "${ACTUAL_SIGNER:u}" != "${SIGN_IDENTITY:u}" ]]; then
  echo "Signing certificate mismatch. Installation stopped." >&2
  exit 1
fi
if [[ "$BUILD_ONLY" == "1" ]]; then
  rm -rf "$ROOT/.build/Mivo.app"
  ditto "$STAGING/Mivo.app" "$ROOT/.build/Mivo.app"
  echo "Built $ROOT/.build/Mivo.app"
  exit 0
fi
# Identical builds need not replace an already authorised installation.
if [[ -f "$APP/Contents/MacOS/DJIMicHold" ]] \
  && cmp -s "$STAGING/Mivo.app/Contents/MacOS/DJIMicHold" "$APP/Contents/MacOS/DJIMicHold" \
  && cmp -s "$STAGING/Mivo.app/Contents/Info.plist" "$APP/Contents/Info.plist" \
  && cmp -s "$ICON" "$APP/Contents/Resources/Mivo.icns" \
  && codesign --verify --strict "$APP"; then
  echo "Already installed (unchanged): $APP"
  exit 0
fi
if pgrep -f '^/Applications/Mivo.app/Contents/MacOS/DJIMicHold($| )' >/dev/null; then
  echo "Mivo is running. Quit Mivo before replacing it so the running process and permission identity stay consistent." >&2
  exit 1
fi
ditto "$STAGING/Mivo.app" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "$BUILD_KEY" > "$ROOT/.build/install-source"
shasum -a 256 "$APP/Contents/MacOS/DJIMicHold" | cut -d ' ' -f 1 > "$ROOT/.build/install-binary"
echo "Installed $APP"
