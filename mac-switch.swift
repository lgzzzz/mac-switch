//
// mac-switch.swift
//
// 持续监听一个可配置的全局热键(默认 alt+tab),按下时在 config.json 里配置的
// 应用列表之间循环切换窗口:
//   - 前台应用在列表中 → 激活列表中的下一个(末尾回到开头);
//   - 前台应用不在列表中 → 激活 fallbackIndex 指定的那个(默认第 0 个)。
//
// 应用列表、热键、回退位置全部由配置文件决定,程序本身不绑定任何具体应用。
//
// 原理:CGEventTap 全局键盘事件钩子(macOS 会话级)。
//   需要「输入监控」权限;若要拦截按键(被切换的应用不弹 Switcher),建议同时授予「辅助功能」。
//
// 编译: swiftc -O mac-switch.swift -o mac-switch
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 路径解析

// 仓库根目录:取「可执行文件所在目录」。
//   - 直接运行裸二进制(./mac-switch)时,二进制就放在仓库根目录;
//   - 通过 .app 启动时,可执行文件位于 <仓库>/MacSwitch.app/Contents/MacOS/,
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

// 把路径解析为绝对路径(源码里不写死机器相关路径):
//   - 绝对路径原样返回;
//   - ~ 开头按当前用户主目录展开;
//   - 其余按 base 解析。
func absoluteURL(_ path: String, relativeTo base: URL) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
}

func fail(_ message: String) -> Never {
    fputs("❌ \(message)\n", stderr)
    exit(1)
}

// MARK: - 配置文件的数据结构

// 修饰键支持两种写法: "alt" / "alt+shift" 字符串,或 ["alt", "shift"] 数组。
struct ModifierSpec: Codable {
    let names: [String]

    init(names: [String]) { self.names = names }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            names = single.split(separator: "+").map(String.init)
        } else {
            names = try container.decode([String].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if names.count == 1 {
            try container.encode(names[0])
        } else {
            try container.encode(names)
        }
    }
}

struct ConfigHotkey: Codable {
    var modifier: ModifierSpec?
    var keycode: Int?
}

struct ConfigApp: Codable {
    var name: String?
    var bundleId: String?
    var path: String?
}

struct ConfigFile: Codable {
    var hotkey: ConfigHotkey?
    var apps: [ConfigApp]?
    var fallbackIndex: Int?
}

// MARK: - 解析后的运行时配置

struct TargetApp {
    let name: String
    let bundleID: String
    let path: String?
}

struct AppConfig {
    let configPath: String
    let apps: [TargetApp]
    let fallbackIndex: Int
    let keycode: Int64
    let modifierNames: [String]        // 规范顺序: ctrl, alt, cmd, shift
    let modifierFlags: CGEventFlags
    let modifierSource: String         // 原始配置值,用于 --print-config 回显
}

// MARK: - 热键解析

let modifierTable: [(aliases: [String], canonical: String, flag: CGEventFlags)] = [
    (["ctrl", "control"], "ctrl", .maskControl),
    (["alt", "option", "opt"], "alt", .maskAlternate),
    (["cmd", "command", "meta", "super"], "cmd", .maskCommand),
    (["shift"], "shift", .maskShift),
]

let allModifierFlags: [CGEventFlags] = modifierTable.map { $0.flag }

func parseModifiers(_ names: [String]) -> (canonical: [String], flags: CGEventFlags) {
    var wanted = Set<String>()
    for raw in names {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.isEmpty { continue }
        guard let entry = modifierTable.first(where: { $0.aliases.contains(token) }) else {
            fail("未知的修饰键「\(raw)」,支持:ctrl(control) / alt(option) / cmd(command) / shift,"
                 + "多个用 + 连接,例如 alt+shift。")
        }
        wanted.insert(entry.canonical)
    }
    guard !wanted.isEmpty else {
        fail("hotkey.modifier 为空:至少要指定一个修饰键(ctrl / alt / cmd / shift)。")
    }
    // 按 ctrl, alt, cmd, shift 的固定顺序输出,保证显示与匹配都稳定
    var canonical: [String] = []
    var flags: CGEventFlags = []
    for entry in modifierTable where wanted.contains(entry.canonical) {
        canonical.append(entry.canonical)
        flags.insert(entry.flag)
    }
    return (canonical, flags)
}

func keyDisplayName(_ keycode: Int64) -> String {
    switch keycode {
    case 48: return "tab"
    case 49: return "space"
    case 36: return "return"
    case 53: return "esc"
    case 51: return "delete"
    case 123: return "left"
    case 124: return "right"
    default: return "keycode \(keycode)"
    }
}

func hotkeyDisplayName(_ config: AppConfig) -> String {
    (config.modifierNames + [keyDisplayName(config.keycode)]).joined(separator: "+")
}

// 事件修饰键必须与配置完全一致:该按的都按下,不该按的都没按。
func modifiersMatch(_ flags: CGEventFlags, required: CGEventFlags) -> Bool {
    for flag in allModifierFlags where flags.contains(flag) != required.contains(flag) {
        return false
    }
    return true
}

// MARK: - 配置加载

func describeDecodingError(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else { return error.localizedDescription }
    func location(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? "(根)" : path
    }
    switch decodingError {
    case .keyNotFound(let key, let context):
        return "缺少字段 \(location(context)).\(key.stringValue)"
    case .typeMismatch(_, let context):
        return "字段类型错误:\(location(context))"
    case .valueNotFound(_, let context):
        return "字段值为空:\(location(context))"
    case .dataCorrupted(let context):
        return "JSON 格式错误:\(context.debugDescription)"
    @unknown default:
        return decodingError.localizedDescription
    }
}

let configTemplate = """
{
  "hotkey": { "modifier": "alt", "keycode": 48 },
  "apps": [
    { "name": "Safari", "bundleId": "com.apple.Safari" },
    { "name": "Notes", "path": "/System/Applications/Notes.app" }
  ]
}
"""

func loadConfigFile(at url: URL) -> ConfigFile {
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("""
        找不到配置文件:\(url.path)
        请创建该文件(或用 --config <路径> 指定),内容示例:
        \(configTemplate)
        """)
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        fail("无法读取配置文件 \(url.path):\(error.localizedDescription)")
    }
    do {
        return try JSONDecoder().decode(ConfigFile.self, from: data)
    } catch {
        fail("""
        配置文件 \(url.path) 解析失败:\(describeDecodingError(error))
        提示:必须是合法 JSON(不支持注释);未知字段会被忽略,可用 "_comment" 字段写备注。
        """)
    }
}

func buildConfig(from file: ConfigFile, configURL: URL) -> AppConfig {
    let baseDir = configURL.deletingLastPathComponent()

    guard let rawApps = file.apps, !rawApps.isEmpty else {
        fail("配置文件 \(configURL.path) 的 apps 为空:至少需要配置一个应用。")
    }

    var apps: [TargetApp] = []
    for (index, raw) in rawApps.enumerated() {
        let trimmedName = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = trimmedName?.isEmpty == false
        let label = hasName ? trimmedName! : "apps[\(index)]"

        // 相对路径按「配置文件所在目录」解析,便于配置与程序分离存放
        let path: String? = raw.path.map { absoluteURL($0, relativeTo: baseDir).path }
        let pathExists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false

        var bundleID = raw.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleID.isEmpty, let p = path, pathExists {
            // 没写 bundleId 时,尝试从 .app 里读出它的 bundle identifier
            bundleID = Bundle(url: URL(fileURLWithPath: p))?
                .bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        if bundleID.isEmpty {
            let reason: String
            if let p = path {
                reason = pathExists ? "path「\(p)」里读不出 bundle identifier" : "path「\(p)」不存在"
            } else {
                reason = "未配置 path"
            }
            fail("apps[\(index)](\(label)) 无法定位:bundleId 为空,且 \(reason)。")
        }
        if let p = path, !pathExists {
            fputs("⚠️ apps[\(index)](\(label)) 的 path 不存在,将只按 bundleId 查找:\(p)\n", stderr)
        }

        // 未写 name 时,用 bundle id 作为显示名(便于日志与启动横幅辨认)
        apps.append(TargetApp(name: hasName ? trimmedName! : bundleID, bundleID: bundleID, path: path))
    }

    let fallbackIndex = file.fallbackIndex ?? 0
    guard apps.indices.contains(fallbackIndex) else {
        fail("fallbackIndex = \(fallbackIndex) 超出范围:可选 0...\(apps.count - 1)(共 \(apps.count) 个应用)。")
    }

    // 热键默认值:alt + Tab(键码 48)
    let rawModifier = file.hotkey?.modifier?.names ?? ["alt"]
    let parsed = parseModifiers(rawModifier)
    var keycode: Int64 = 48
    if let configured = file.hotkey?.keycode {
        guard configured >= 0, configured <= 255 else {
            fail("hotkey.keycode = \(configured) 不合法:应为 0...255 的虚拟键码。")
        }
        keycode = Int64(configured)
    }

    return AppConfig(configPath: configURL.path,
                     apps: apps,
                     fallbackIndex: fallbackIndex,
                     keycode: keycode,
                     modifierNames: parsed.canonical,
                     modifierFlags: parsed.flags,
                     modifierSource: rawModifier.joined(separator: "+"))
}

// MARK: - 命令行参数

struct Options {
    var configPath: String?
    var keycode: Int64?
    var modifier: String?
    var checkOnly = false
    var printConfigOnly = false
}

func printUsage() {
    print("""
    mac-switch —— 用可配置的全局热键在多个应用之间循环切换窗口

    用法: mac-switch [选项]

    应用列表与热键来自配置文件(默认 <仓库根>/config.json),程序不绑定任何具体应用。

    选项:
      --config <路径>     指定配置文件(默认 ./config.json;相对路径按当前工作目录解析)
      --keycode <数字>    覆盖配置里的热键键码(macOS 虚拟键码,0...255;48 = Tab,49 = 空格)
      --modifier <名称>   覆盖配置里的修饰键,如 alt、cmd、alt+shift
      --print-config      打印解析后的完整配置(含绝对路径)后退出,用于排查配置问题
      --check             只检查「输入监控」「辅助功能」权限,不启动监听
      -h, --help          显示帮助

    配置文件示例:
    \(configTemplate)

    行为: 按下热键时,若前台应用在 apps 列表里,则切换到它的下一个(末尾回到开头);
          若前台应用不在列表里,则切换到 fallbackIndex 指定的应用(默认第 0 个)。

    注意: 默认按键是「纯 option(alt)+tab」,多按或少按其它修饰键都不会触发。
    """)
}

func parseOptions() -> Options {
    var options = Options()
    let argv = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < argv.count {
        let arg = argv[index]
        func value(for name: String) -> String {
            guard index + 1 < argv.count else {
                fputs("缺少参数值: \(name)\n", stderr)
                exit(2)
            }
            return argv[index + 1]
        }
        switch arg {
        case "-h", "--help":
            printUsage(); exit(0)
        case "--config":
            options.configPath = value(for: "--config"); index += 1
        case "--keycode":
            let raw = value(for: "--keycode")
            guard let parsed = Int64(raw), parsed >= 0, parsed <= 255 else {
                fputs("--keycode 需要 0...255 的整数,收到: \(raw)\n", stderr)
                exit(2)
            }
            options.keycode = parsed; index += 1
        case "--modifier":
            options.modifier = value(for: "--modifier"); index += 1
        case "--print-config":
            options.printConfigOnly = true
        case "--check":
            options.checkOnly = true
        default:
            fputs("未知参数: \(arg)\n", stderr)
            printUsage(); exit(2)
        }
        index += 1
    }
    return options
}

// MARK: - --print-config

func appIsLocatable(_ app: TargetApp) -> Bool {
    if !app.bundleID.isEmpty,
       NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil {
        return true
    }
    if let p = app.path, FileManager.default.fileExists(atPath: p) { return true }
    return false
}

func printResolvedConfig(_ config: AppConfig) {
    var appsJSON: [[String: Any]] = []
    for app in config.apps {
        var entry: [String: Any] = [
            "name": app.name,
            "bundleId": app.bundleID,
            "located": appIsLocatable(app),
        ]
        if let path = app.path {
            entry["path"] = path
        } else {
            entry["path"] = NSNull()
        }
        appsJSON.append(entry)
    }
    let payload: [String: Any] = [
        "configPath": config.configPath,
        "hotkey": [
            "modifier": config.modifierSource,
            "modifiersCanonical": config.modifierNames,
            "keycode": Int(config.keycode),
            "display": hotkeyDisplayName(config),
        ],
        "fallbackIndex": config.fallbackIndex,
        "apps": appsJSON,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        fail("序列化配置失败。")
    }
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
        ⚠️ 还需要「辅助功能」权限(用于拦截按键,避免被切换的应用弹出 Switcher)。
        macOS 已弹出授权请求,允许后请重新运行本程序。

        """, stderr)
        return false
    }
    return true
}

func printPermissionStatus() {
    if #available(macOS 10.15, *) {
        if CGPreflightListenEventAccess() {
            print("✅ 输入监控权限已授予,可以正常监听按键。")
        } else {
            print("❌ 尚未授予输入监控权限。运行本程序时会弹出系统请求,或到 系统设置 > 隐私与安全性 > 输入监控 中手动勾选。")
        }
    } else {
        print("当前系统无需单独授予输入监控权限。")
    }
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) {
        print("✅ 辅助功能权限已授予,按键会被拦截(被切换的应用不会弹 Switcher)。")
    } else {
        print("❌ 尚未授予辅助功能权限。热键仍可触发,但可能同时被目标应用自己处理。")
    }
}

// MARK: - 应用切换

@discardableResult
func activateApp(_ app: TargetApp) -> Bool {
    var appURL: URL?
    if !app.bundleID.isEmpty {
        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }
    if appURL == nil, let path = app.path, FileManager.default.fileExists(atPath: path) {
        appURL = URL(fileURLWithPath: path)
    }
    guard let url = appURL else {
        fputs("❌ 找不到应用「\(app.name)」(bundleId: \(app.bundleID)),也没有可用的 path。\n", stderr)
        return false
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error = error {
            fputs("❌ 切换窗口失败(\(app.name)): \(error.localizedDescription)\n", stderr)
        }
    }
    return true
}

// 找出前台应用在列表中的位置:bundle id 优先,path 兜底(适用于没有 bundle id 的场景)
func frontmostIndex(in apps: [TargetApp]) -> Int? {
    let frontmost = NSWorkspace.shared.frontmostApplication
    let frontBundleID = frontmost?.bundleIdentifier
    let frontPath = frontmost?.bundleURL?.standardizedFileURL.path
    for (index, app) in apps.enumerated() {
        if let frontBundleID, !app.bundleID.isEmpty, frontBundleID == app.bundleID {
            return index
        }
        if let frontPath, let appPath = app.path,
           frontPath == URL(fileURLWithPath: appPath).standardizedFileURL.path {
            return index
        }
    }
    return nil
}

// MARK: - 事件回调

var appConfig: AppConfig!
var lastSwitchAt: Double = 0

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    // 1. 只关心目标键
    guard event.getIntegerValueField(.keyboardEventKeycode) == appConfig.keycode else {
        return Unmanaged.passUnretained(event)
    }

    // 2. 修饰键必须与配置完全一致(纯 alt+tab 时,带 shift/ctrl/cmd 的组合不触发)
    guard modifiersMatch(event.flags, required: appConfig.modifierFlags) else {
        return Unmanaged.passUnretained(event)
    }

    // 3. 忽略按键自动重复(按住不放产生的重复 keyDown)
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    // 4. 计算目标:列表内则取下一个(循环),列表外则取 fallbackIndex
    let apps = appConfig.apps
    let targetIndex: Int
    if let current = frontmostIndex(in: apps) {
        targetIndex = (current + 1) % apps.count
    } else {
        targetIndex = appConfig.fallbackIndex
    }
    let target = apps[targetIndex]

    // 5. 防抖: 200ms 内的重复触发只算一次
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSwitchAt > 0.2 else { return nil }
    lastSwitchAt = now

    if activateApp(target) {
        print("\(hotkeyDisplayName(appConfig)) → \(target.name)")
        return nil  // 吞掉本次按键,避免被切换的应用弹出 Switcher
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - main

// 通过 open/launchd 启动时 stdout/stderr 不是终端,重定向到日志文件方便排查
func redirectLogsIfNeeded() {
    if isatty(STDOUT_FILENO) == 0 {
        freopen("/tmp/mac-switch.app.out.log", "a", stdout)
    }
    if isatty(STDERR_FILENO) == 0 {
        freopen("/tmp/mac-switch.app.err.log", "a", stderr)
    }
}

func main() {
    let options = parseOptions()

    // 定位配置文件:--config 优先(相对当前工作目录),否则仓库根目录下的 config.json
    let configURL: URL
    if let explicit = options.configPath {
        configURL = absoluteURL(explicit, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    } else {
        configURL = repoRoot().appendingPathComponent("config.json")
    }

    var config = buildConfig(from: loadConfigFile(at: configURL), configURL: configURL)

    // 命令行覆盖配置文件里的热键(仅本次运行,不写回文件)
    if let modifier = options.modifier {
        let parsed = parseModifiers(modifier.split(separator: "+").map(String.init))
        config = AppConfig(configPath: config.configPath,
                           apps: config.apps,
                           fallbackIndex: config.fallbackIndex,
                           keycode: config.keycode,
                           modifierNames: parsed.canonical,
                           modifierFlags: parsed.flags,
                           modifierSource: modifier)
    }
    if let keycode = options.keycode {
        config = AppConfig(configPath: config.configPath,
                           apps: config.apps,
                           fallbackIndex: config.fallbackIndex,
                           keycode: keycode,
                           modifierNames: config.modifierNames,
                           modifierFlags: config.modifierFlags,
                           modifierSource: config.modifierSource)
    }

    if options.printConfigOnly {
        printResolvedConfig(config)
        exit(0)
    }
    if options.checkOnly {
        printPermissionStatus()
        exit(0)
    }

    appConfig = config
    redirectLogsIfNeeded()

    if config.apps.count < 2 {
        fputs("⚠️ 只配置了 \(config.apps.count) 个应用,循环切换不会产生变化。\n", stderr)
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

    let cycle = config.apps.map { $0.name }.joined(separator: " → ") + " → " + config.apps[0].name
    print("""
    ✅ mac-switch 已启动。
       配置文件: \(config.configPath)
       热键: \(hotkeyDisplayName(config))
       循环顺序: \(cycle)
       前台不在列表时切到: \(config.apps[config.fallbackIndex].name)
       按 Ctrl+C 退出。

    """)
    CFRunLoopRun()
}

main()
