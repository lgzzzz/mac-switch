#!/bin/bash
# 安装 mac-switch:
#   1. 编译 Swift 程序
#   2. 校验 config.json(应用列表与热键都在这里配置)
#   3. 打包为 MacSwitch.app(带 bundle,授权弹窗可可靠出现)
#   4. 注册 LaunchAgent:登录后自动通过 open 启动该 app
set -euo pipefail
cd "$(dirname "$0")"

SWIFT=mac-switch.swift
BIN="$PWD/mac-switch"
APP_NAME=MacSwitch
APP="$PWD/$APP_NAME.app"
LABEL=com.macswitch.agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 编译 $SWIFT ..."
# 优先用 Xcode 自带工具链(部分机器上 CommandLineTools 的 SDK 与 swiftc 版本不匹配)
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swiftc -O "$SWIFT" -o "$BIN"

echo "==> 校验配置 config.json ..."
if [ ! -f config.json ]; then
  if [ -f config.example.json ]; then
    cp config.example.json config.json
    echo "    未找到 config.json,已从 config.example.json 生成一份模板。"
    echo "    ⚠️ 模板里的 apps 只是示例,请编辑 config.json 改成你要切换的应用,然后重启服务:"
    echo "        launchctl kickstart -k gui/\$(id -u)/$LABEL"
  else
    echo "❌ 缺少 config.json,也找不到 config.example.json;" >&2
    echo "   请创建 config.json(至少要有 apps 列表),格式见 README.md。" >&2
    exit 1
  fi
fi
# 校验失败时程序会打印具体原因到 stderr 并以非 0 退出,set -e 会让脚本在此中止
"$BIN" --print-config >/dev/null
echo "    配置有效。"

echo "==> 打包 $APP_NAME.app ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/mac-switch"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.macswitch.app</string>
  <key>CFBundleName</key>
  <string>MacSwitch</string>
  <key>CFBundleDisplayName</key>
  <string>MacSwitch</string>
  <key>CFBundleExecutable</key>
  <string>mac-switch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
</dict>
</plist>
EOF

echo "==> ad-hoc 签名(保证 TCC 权限身份稳定)..."
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"

echo "==> 写入 LaunchAgent: $LABEL(通过 open 启动 $APP_NAME.app)..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/mac-switch.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/mac-switch.err.log</string>
</dict>
</plist>
EOF

# 杀掉已在运行的进程(裸二进制或 app),重载服务
pkill -x mac-switch 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

sleep 2
if pgrep -f "$APP/Contents/MacOS/mac-switch" >/dev/null 2>&1; then
  echo
  echo "✅ $APP_NAME 已在运行。当前生效的配置:"
  "$BIN" --print-config | sed 's/^/   /'
  echo
  echo "   按上面 hotkey.display 组合键即可在 apps 列表间循环切换。"
  echo "   程序日志: /tmp/mac-switch.app.out.log /tmp/mac-switch.app.err.log"
else
  echo
  echo "⚠️ 程序启动后退出 —— 首次安装需要依次授予两个权限(每次授权后需要重启它):"
  echo "   1) 允许屏幕上的「输入监控」弹窗(应用名: $APP_NAME),然后执行:"
  echo "        launchctl kickstart -k gui/\$(id -u)/$LABEL"
  echo "   2) 再允许「辅助功能」弹窗,再次执行上面的 kickstart。"
  echo
  echo "   日志: /tmp/mac-switch.app.out.log /tmp/mac-switch.app.err.log"
  echo "   若弹窗没有出现: 系统设置 > 隐私与安全性 > 输入监控 / 辅助功能 中手动添加 $APP"
fi
