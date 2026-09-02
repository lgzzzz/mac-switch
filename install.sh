#!/bin/bash
# 安装 ds-window-switch:
#   1. 编译 Swift 程序
#   2. 打包为 DSWindowSwitch.app(带 bundle,授权弹窗可可靠出现)
#   3. 注册 LaunchAgent:登录后自动通过 open 启动该 app
set -euo pipefail
cd "$(dirname "$0")"

SWIFT=ds-window-switch.swift
BIN="$PWD/ds-window-switch"
APP_NAME=DSWindowSwitch
APP="$PWD/$APP_NAME.app"
LABEL=ds.window.switch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 编译 $SWIFT ..."
# 优先用 Xcode 自带工具链(部分机器上 CommandLineTools 的 SDK 与 swiftc 版本不匹配)
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swiftc -O "$SWIFT" -o "$BIN"

echo "==> 打包 $APP_NAME.app ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ds-window-switch"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.dshswitch.windowswitch</string>
  <key>CFBundleName</key>
  <string>DSWindowSwitch</string>
  <key>CFBundleDisplayName</key>
  <string>DSWindowSwitch</string>
  <key>CFBundleExecutable</key>
  <string>ds-window-switch</string>
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
  <string>/tmp/$LABEL.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$LABEL.err.log</string>
</dict>
</plist>
EOF

# 杀掉旧进程(裸二进制或旧 app),重载服务
pkill -x ds-window-switch 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

sleep 2
if pgrep -f "$APP/Contents/MacOS/ds-window-switch" >/dev/null 2>&1; then
  echo
  echo "✅ $APP_NAME 已在运行,且权限已就绪。去 IDEA 里按 alt+tab 试试。"
  echo "   程序日志: /tmp/ds.window.switch.app.out.log /tmp/ds.window.switch.app.err.log"
else
  echo
  echo "⚠️ 程序启动后退出 —— 首次安装需要依次授予两个权限(每次授权后需要重启它):"
  echo "   1) 允许屏幕上的「输入监控」弹窗(应用名: $APP_NAME),然后执行:"
  echo "        launchctl kickstart -k gui/\$(id -u)/$LABEL"
  echo "   2) 再允许「辅助功能」弹窗,再次执行上面的 kickstart。"
  echo "   完成后去 IDEA 里按 alt+tab 验证。"
  echo
  echo "   日志: /tmp/ds.window.switch.app.out.log /tmp/ds.window.switch.app.err.log"
  echo "   若弹窗没有出现: 系统设置 > 隐私与安全性 > 输入监控 / 辅助功能 中手动添加 $APP"
fi
