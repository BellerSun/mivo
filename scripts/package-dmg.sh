#!/bin/zsh
# Package an already-signed app without rebuilding or changing its identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 2 ]]; then
  echo "Usage: $0 <signed-Mivo.app> <output.dmg>" >&2
  exit 1
fi
APP="$(cd "$1" && pwd)"
OUTPUT="${2:a}"
if [[ "${OUTPUT:e}" != "dmg" || -e "$OUTPUT" ]]; then
  echo "Output must be a new .dmg path; existing files will not be overwritten." >&2
  exit 1
fi
codesign --verify --strict "$APP"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
if info.get('CFBundleIdentifier') != 'local.dji.mic-hold.menu':
    raise SystemExit('Expected a signed Mivo application.')
PY
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/mivo-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/说明与许可" "${OUTPUT:h}"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGING/Mivo.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/LICENSE" "$STAGING/说明与许可/LICENSE.txt"
cat > "$STAGING/说明与许可/安装说明.txt" <<'TXT'
先退出正在运行的 Mivo，再将 Mivo.app 拖到 Applications 文件夹。
请使用固定安装位置 /Applications/Mivo.app，不要直接从磁盘映像运行。
复制完成后推出磁盘映像，从“应用程序”打开 Mivo。
首次使用请在 Mivo 设置中开启辅助功能和输入监控。

本试用包中的应用使用维护者固定本机开发证书签名，未使用 Developer ID，也未经 Apple 公证。
Gatekeeper 可能阻止打开；不要关闭系统保护。也可按仓库说明自行构建。
此包仅支持 Apple Silicon。Fn 为实验支持，目标应用兼容性需实测。
https://github.com/BellerSun/mivo
TXT
codesign --verify --strict "$STAGING/Mivo.app"
hdiutil create -volname Mivo -srcfolder "$STAGING" -format UDZO -fs HFS+ "$OUTPUT"
hdiutil verify "$OUTPUT"
echo "Packaged $OUTPUT"
