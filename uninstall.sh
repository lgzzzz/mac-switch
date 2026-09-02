#!/bin/bash
# 卸载 ds-window-switch:停止并删除 LaunchAgent、编译产物与 app 打包。
set -euo pipefail
LABEL=ds.window.switch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"

pkill -x ds-window-switch 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$DIR/ds-window-switch"
rm -rf "$DIR/DSWindowSwitch.app"

echo "✅ 已卸载。"
echo "   若之前授予过权限,可在 系统设置 > 隐私与安全性 > 输入监控 / 辅助功能 中移除 DSWindowSwitch(或 ds-window-switch)。"
