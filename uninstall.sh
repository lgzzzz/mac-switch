#!/bin/bash
# 卸载 mac-switch:停止进程、删除 LaunchAgent、编译产物与 app 打包。
# 配置文件 config.json 属于用户数据,会被保留。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

LABEL=com.macswitch.agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

pkill -x mac-switch 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$DIR/mac-switch"
rm -rf "$DIR/MacSwitch.app"

echo "✅ 已卸载(保留配置文件 config.json 未删除)。"
echo "   若之前授予过权限,可在 系统设置 > 隐私与安全性 > 输入监控 / 辅助功能 中移除 MacSwitch。"
