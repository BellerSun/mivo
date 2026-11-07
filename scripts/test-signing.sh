#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/test-signing-tools.py"
SIGN_IDENTITY="${MIVO_SIGNING_IDENTITY:-$(python3 "$ROOT/scripts/signing-config.py" identity)}"
SIGN_KEYCHAIN="${MIVO_SIGNING_KEYCHAIN:-$(python3 "$ROOT/scripts/signing-config.py" keychain)}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mivo-signing-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
for VERSION in 1 2; do
  printf '#include <stdio.h>\nint main(void) { puts("Mivo build %s"); return 0; }\n' "$VERSION" > "$TEST_DIR/v$VERSION.c"
  clang "$TEST_DIR/v$VERSION.c" -o "$TEST_DIR/v$VERSION"
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
    --identifier local.mivo.signing-regression --timestamp=none "$TEST_DIR/v$VERSION"
  codesign --verify --strict "$TEST_DIR/v$VERSION"
  codesign -d -r- "$TEST_DIR/v$VERSION" 2>&1 | sed -n 's/^designated => //p' > "$TEST_DIR/v$VERSION.requirement"
done
cmp "$TEST_DIR/v1.requirement" "$TEST_DIR/v2.requirement"
if rg -q cdhash "$TEST_DIR/v1.requirement"; then
  echo 'FAIL: identity still depends on the build hash.' >&2
  exit 1
fi
codesign --verify --strict -R "=$(cat "$TEST_DIR/v1.requirement")" "$TEST_DIR/v2"
codesign --verify --strict -R "=$(cat "$TEST_DIR/v2.requirement")" "$TEST_DIR/v1"
if cmp -s "$TEST_DIR/v1" "$TEST_DIR/v2"; then
  echo 'FAIL: test versions must contain different code.' >&2
  exit 1
fi
cp "$TEST_DIR/v2" "$TEST_DIR/other-signer"
codesign --force --sign - --identifier local.mivo.signing-regression --timestamp=none "$TEST_DIR/other-signer"
if codesign --verify --strict -R "=$(cat "$TEST_DIR/v1.requirement")" "$TEST_DIR/other-signer" >/dev/null 2>&1; then
  echo 'FAIL: an unrelated signature impersonated the pinned identity.' >&2
  exit 1
fi
printf 'PASS: an unrelated signature with the same bundle ID is rejected.\n'
printf 'PASS: different code versions satisfy the same certificate-pinned signing identity.\n'
cat "$TEST_DIR/v1.requirement"
