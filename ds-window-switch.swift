//
// ds-window-switch.swift
//
// 持续监听 alt+tab:按下时在 IntelliJ IDEA 与 DeepSeek Harness 之间切换窗口;
// 两个应用都不在前台时,先切换到 DeepSeek Harness。
//
// 原理:CGEventTap 全局键盘事件钩子(macOS 会话级)。
//   需要「输入监控」权限;若要拦截按键(IDEA 不弹 Switcher),建议同时授予「辅助功能」。
//
// 编译: swiftc -O ds-window-switch.swift -o ds-window-switch
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 默认配置(可用命令行参数覆盖)

// 仓库根目录:取「可执行文件所在目录」。
//   - 直接运行裸二进制(./ds-window-switch)时,二进制就放在仓库根目录;
//   - 通过 .app 启动时,可执行文件位于 <仓库>/DSWindowSwitch.app/Contents/MacOS/,
//     需向上退回仓库根目录(假设 .app 保持在仓库根目录,install.sh 即如此打包)。
func repoRoot() -> URL {
    let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL.standardizedFileURL
    let exeURL = (Bundle.main.executableURL ?? argv0).standardizedFileURL
    let exeDir = exeURL.deletingLastPathComponent().standardizedFileURL
    let inApp = exeDir.lastPathComponent == "MacOS"
        && exeDir.deletingLastPathComponent().lastPathComponent == "Contents"
    return inApp
        ? exeDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        : exeDir
}

// 把路径解析为可用的绝对路径(不在源码里写死机器相关路径):
//   - 绝对路径原样返回;
//   - ~ 开头的路径按当前用户主目录展开;
//   - 其余相对路径按「仓库根目录」解析。
func resolvePath(_ p: String) -> String {
    let expanded = (p as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: expanded, relativeTo: repoRoot()).standardizedFileURL.path
}

var ideaBundleID      = "com.jetbrains.intellij"
var harnessBundleID   = "dsh-electron"
// DeepSeek Harness.app 的默认位置:相对仓库根解析(仓库的上一级,即与仓库目录同级,
// 例如仓库在 ~/mac-switch 时默认 ~/DeepSeek Harness.app)。用 --harness-path 可覆盖。
var harnessAppPath    = resolvePath("../DeepSeek Harness.app")
var switchKeycode: Int64 = 48   // kVK_Tab;其他键可查 HIToolbox 的 kVK_* 常量
var switchModifier: CGEventFlags = .maskAlternate   // 默认 alt(option);可用 --modifier 改为 ctrl/cmd/shift
let allModifierFlags: [CGEventFlags] = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

func modifierDisplayName() -> String {
    switch switchModifier {
    case .maskAlternate: return "alt+tab"
    case .maskCommand:   return "cmd+tab"
    case .maskShift:     return "shift+tab"
    default:             return "ctrl+tab"
    }
}

// MARK: - 命令行参数

func printUsage() {
    print("""
    ds-window-switch —— 用 alt+tab 在 IntelliJ IDEA 与 DeepSeek Harness 之间切换

    用法: ds-window-switch [选项]

    选项:
      --idea <bundle-id>       IDEA 的 bundle identifier(默认 \(ideaBundleID))
      --harness <bundle-id>    DeepSeek Harness 的 bundle identifier(默认 \(harnessBundleID))
      --harness-path <路径>    DeepSeek Harness.app 路径(应用未注册到系统时用于启动它)
      --keycode <数字>         切换键的虚拟键码(默认 48 = Tab)
      --modifier <名称>        修饰键: ctrl / alt / cmd / shift(默认 alt)
      --check                  只检查「输入监控」权限,不启动监听
      -h, --help               显示帮助

    默认按键: 纯 option(alt)+tab(带 shift/ctrl/cmd 的组合不触发)。
    按下即切换;两个应用都不在前台时,先切换到 DeepSeek Harness。
    """)
}

var argv = Array(CommandLine.arguments.dropFirst())
var idx = 0
while idx < argv.count {
    let arg = argv[idx]
    func value(for name: String) -> String {
        guard idx + 1 < argv.count else {
            fputs("缺少参数值: \(name)\n", stderr)
            exit(2)
        }
        return argv[idx + 1]
    }
    switch arg {
    case "-h", "--help":
        printUsage(); exit(0)
    case "--idea":
        ideaBundleID = value(for: "--idea"); idx += 1
    case "--harness":
        harnessBundleID = value(for: "--harness"); idx += 1
    case "--harness-path":
        harnessAppPath = resolvePath(value(for: "--harness-path")); idx += 1
    case "--keycode":
        switchKeycode = Int64(value(for: "--keycode")) ?? switchKeycode; idx += 1
    case "--modifier":
        switch value(for: "--modifier").lowercased() {
        case "ctrl", "control": switchModifier = .maskControl
        case "alt", "option":   switchModifier = .maskAlternate
        case "cmd", "command":  switchModifier = .maskCommand
        case "shift":           switchModifier = .maskShift
        default:
            fputs("未知 modifier(支持 ctrl/alt/cmd/shift)。\n", stderr)
            exit(2)
        }
        idx += 1
    case "--check":
        if #available(macOS 10.15, *) {
            if CGPreflightListenEventAccess() {
                print("✅ 输入监控权限已授予,可以正常监听按键。")
            } else {
                print("❌ 尚未授予输入监控权限。运行本程序时会弹出系统请求,或到 系统设置 > 隐私与安全性 > 输入监控 中手动勾选。")
            }
        } else {
            print("当前系统无需单独授予输入监控权限。")
        }
        exit(0)
    default:
        fputs("未知参数: \(arg)\n", stderr)
        printUsage(); exit(2)
    }
    idx += 1
}

// MARK: - 权限

func ensureEventTapPermission() -> Bool {
    if #available(macOS 10.15, *) {
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            fputs("""
            ⚠️ 需要「输入监控」权限才能监听按键。macOS 已弹出授权请求
            (或到 系统设置 > 隐私与安全性 > 输入监控 中勾选本程序 / 你启动它的终端)。
            授权后请重新运行本程序。

            """, stderr)
            return false
        }
    }
    // 活动事件钩子(.defaultTap,可拦截按键)还需要「辅助功能」权限
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
        fputs("""
        ⚠️ 还需要「辅助功能」权限(用于拦截按键,防止 IDEA 弹出 Switcher)。
        macOS 已弹出授权请求,允许后请重新运行本程序。

        """, stderr)
        return false
    }
    return true
}

// MARK: - 应用切换

@discardableResult
func activateApp(bundleID: String, fallbackPath: String?) -> Bool {
    var appURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    if appURL == nil, let p = fallbackPath, FileManager.default.fileExists(atPath: p) {
        appURL = URL(fileURLWithPath: p)
    }
    guard let url = appURL else {
        fputs("❌ 找不到应用 \(bundleID),且 fallback 路径不存在。\n", stderr)
        return false
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        if let error = error {
            fputs("❌ 切换窗口失败: \(error.localizedDescription)\n", stderr)
        }
    }
    return true
}

func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

// MARK: - 事件回调

var lastSwitchAt: Double = 0

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    // 1. 只关心目标键
    guard event.getIntegerValueField(.keyboardEventKeycode) == switchKeycode else {
        return Unmanaged.passUnretained(event)
    }

    // 2. 只响应指定修饰键,忽略其他修饰键组合
    let flags = event.flags
    guard flags.contains(switchModifier),
          allModifierFlags.allSatisfy({ $0 == switchModifier || !flags.contains($0) }) else {
        return Unmanaged.passUnretained(event)
    }

    // 3. 忽略按键自动重复(按住不放产生的重复 keyDown)
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    // 4. 始终切换;两个应用都不在前台时,先切到 DeepSeek Harness
    let front = frontmostBundleID()

    let targetBundleID: String
    let targetFallbackPath: String?
    let targetName: String
    switch front {
    case ideaBundleID:
        targetBundleID = harnessBundleID
        targetFallbackPath = harnessAppPath
        targetName = "DeepSeek Harness"
    default:
        targetBundleID = ideaBundleID
        targetFallbackPath = nil
        targetName = "IntelliJ IDEA"
    }

    // 5. 防抖: 200ms 内的重复触发只算一次
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSwitchAt > 0.2 else { return nil }
    lastSwitchAt = now

    if activateApp(bundleID: targetBundleID, fallbackPath: targetFallbackPath) {
        print("\(modifierDisplayName()) → \(targetName)")
        return nil  // 吞掉本次按键,避免 IDEA 弹出 Switcher
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - main

// 通过 open/launchd 启动时 stdout/stderr 不是终端,重定向到日志文件方便排查
if isatty(STDOUT_FILENO) == 0 {
    freopen("/tmp/ds.window.switch.app.out.log", "a", stdout)
}
if isatty(STDERR_FILENO) == 0 {
    freopen("/tmp/ds.window.switch.app.err.log", "a", stderr)
}

guard ensureEventTapPermission() else { exit(1) }

let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: eventMask,
                                  callback: tapCallback,
                                  userInfo: nil) else {
    fputs("""
    ❌ 创建键盘监听失败。请确认已在 系统设置 > 隐私与安全性 > 输入监控
    (必要时再加上 辅助功能)中勾选本程序或启动它的终端,然后重新运行。

    """, stderr)
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("""
✅ ds-window-switch 已启动。
   \(modifierDisplayName()) → 在 IntelliJ IDEA 与 DeepSeek Harness 之间切换(两个应用都不在前台时先切到 DeepSeek Harness)。
   按 Ctrl+C 退出。

""")
CFRunLoopRun()
