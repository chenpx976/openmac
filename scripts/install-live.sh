#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project openmac.xcodeproj -scheme openmac -configuration Debug \
  -derivedDataPath .build/live CODE_SIGNING_ALLOWED=NO build
app="$HOME/Applications/OpenMac Live.app"
if pgrep -f "$app/Contents/MacOS/openmac" >/dev/null; then
  osascript -e 'tell application id "com.chenpx976.openmac.live" to quit'
  for attempt in {1..30}; do
    if ! pgrep -f "$app/Contents/MacOS/openmac" >/dev/null; then break; fi
    sleep 0.2
  done
  if pgrep -f "$app/Contents/MacOS/openmac" >/dev/null; then
    printf '应用尚未退出，请退出后重试。\n' >&2
    exit 1
  fi
fi
mkdir -p "$HOME/Applications"
ditto .build/live/Build/Products/Debug/openmac.app "$app"
# 固定本机开发版本的 designated requirement，避免每次重编译改变 cdhash 而丢失隐私授权。
codesign --force --deep --sign - --identifier com.chenpx976.openmac.live \
  --requirements '=designated => identifier "com.chenpx976.openmac.live"' "$app"
open "$app"
printf '已安装：%s\n首次使用：在消息转发页授权语音识别，并在 Config 中开启 Launch at Login。\n' "$app"
