# mac-switch

持续监听一个可配置的全局热键(默认 **alt(⌥)+tab**),按下时在**配置文件里列出的若干应用**之间循环切换窗口。

程序本身不绑定任何具体应用 —— 切哪几个、按什么键、前台不在列表时去哪个,全部由 `config.json` 决定。

## 切换规则

按一次热键:

- 前台应用**在** `apps` 列表里 → 激活它的**下一个**(到末尾则回到第 0 个);
- 前台应用**不在**列表里 → 激活 `fallbackIndex` 指定的那个(默认第 0 个)。

以 `apps = [IntelliJ IDEA, DeepSeek Harness]`、`fallbackIndex = 1` 为例:在 IDEA 按 → 跳 Harness;在 Harness 按 → 跳 IDEA;在别的应用按 → 先跳 Harness。

列表里放 3 个及以上应用时就是标准的循环轮换。

## 原理

用 macOS 的 CGEventTap(会话级键盘事件钩子)监听指定键 + 指定修饰键的 keyDown,匹配后吞掉该按键(避免被切换的应用弹出自己的 Switcher)并激活目标应用。

无外部依赖,仅使用系统自带的 `swiftc` 编译。

## 配置

配置文件默认是**仓库根目录下的 `config.json`**,也可以用 `--config <路径>` 指定别处。

`config.json` 是**本地私有配置**(每台机器的应用与路径不同),已被 `.gitignore` 忽略、不进版本库。仓库里跟踪的是模板 [config.example.json](config.example.json):

```bash
cp config.example.json config.json   # 首次使用;./install.sh 在你没有 config.json 时也会自动生成
```

下面是一个完整例子(切换到 IntelliJ IDEA 与 DeepSeek Harness):

```json
{
  "hotkey": {
    "modifier": "alt",
    "keycode": 48
  },
  "fallbackIndex": 1,
  "apps": [
    { "name": "IntelliJ IDEA", "bundleId": "com.jetbrains.intellij" },
    { "name": "DeepSeek Harness", "bundleId": "dsh-electron", "path": "../DeepSeek Harness.app" }
  ]
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `apps` | 是 | 参与循环的应用列表,至少 1 个(建议 2 个以上,否则循环没有变化)。顺序即循环顺序。 |
| `apps[].name` | 否 | 显示名,用于日志与启动横幅;省略时用 bundle id 代替。 |
| `apps[].bundleId` | 否 | 应用的 bundle identifier,如 `com.apple.Safari`。与 `path` 至少填一个。 |
| `apps[].path` | 否 | `.app` 路径,在应用未注册到系统(按 bundle id 找不到)时用于定位/启动它。相对路径**按本配置文件所在目录**解析,也支持 `~/...` 与绝对路径。 |
| `hotkey.modifier` | 否 | 修饰键,字符串 `"alt"` / `"alt+shift"`,或数组 `["alt","shift"]`。支持 `ctrl`(`control`)、`alt`(`option`)、`cmd`(`command`/`meta`)、`shift`。默认 `alt`。 |
| `hotkey.keycode` | 否 | 触发键的 macOS 虚拟键码,默认 `48`(Tab)。常用:`36` Return、`49` Space、`53` Esc、`48` Tab。 |
| `fallbackIndex` | 否 | 前台不在 `apps` 里时切到第几个应用(从 0 开始),默认 `0`。 |

说明:

- 修饰键必须**完全匹配**:配置 `"alt"` 时,多按 ctrl/cmd/shift 的组合不会触发(保持"纯 option+tab",不抢系统/应用的组合键)。
- JSON 不支持注释;未知字段会被忽略,可以用 `"_comment"`、`"_comment_paths"` 之类的字段写备注(`config.example.json` 就是这么写的)。
- `path` 存在时如果该 `.app` 读不出 bundle id,而 `bundleId` 又为空,程序会在启动时报错并指出是哪个 `apps[i]`。

### 换个应用 / 多个应用

想切换 Safari、Xcode、Finder 三个应用,按 `cmd+shift+space`:

```json
{
  "hotkey": { "modifier": ["cmd", "shift"], "keycode": 49 },
  "fallbackIndex": 0,
  "apps": [
    { "name": "Safari", "bundleId": "com.apple.Safari" },
    { "name": "Xcode", "bundleId": "com.apple.dt.Xcode" },
    { "name": "Finder", "bundleId": "com.apple.finder" }
  ]
}
```

查某个应用的 bundle id:

```bash
osascript -e 'id of app "Safari"'
mdls -name kMDItemCFBundleIdentifier -r /Applications/Xcode.app
```

## 快速安装(推荐:登录后自动常驻)

```bash
# 进入本仓库目录后执行(脚本内部自行定位自身目录,路径均为相对路径,仓库放哪都能用)
cd ~/mac-switch
./install.sh
```

install.sh 会:编译 → 校验 `config.json`(没有就从 `config.example.json` 生成) → 打包为 `MacSwitch.app`(带 bundle,保证授权弹窗可靠出现)→ ad-hoc 签名 → 注册 LaunchAgent(`com.macswitch.agent`)并通过 `open` 启动该 app。

**首次运行需要依次授予两个权限**(每次授权后重启它一次):

1. 屏幕会弹出「输入监控」授权请求(应用名:**MacSwitch**),允许,然后执行:

```bash
launchctl kickstart -k gui/$(id -u)/com.macswitch.agent
```

2. 接着弹出「辅助功能」授权请求,再允许,再次执行上面的 kickstart。

然后按下你在 `config.json` 里配置的热键(默认 alt+tab)即可验证。改了配置后同样执行上面的 kickstart 让程序重新读取配置(程序只在启动时读一次配置)。

若弹窗没出现:到 `系统设置 > 隐私与安全性 > 输入监控 / 辅助功能`,点 `+` 手动添加本仓库根目录下的 `MacSwitch.app`(用它的完整路径)。

日志:程序本体 `/tmp/mac-switch.app.out.log`、`/tmp/mac-switch.app.err.log`;launchd/open 层 `/tmp/mac-switch.out.log`、`/tmp/mac-switch.err.log`。

## 前台手动运行(调试用)

```bash
./mac-switch                        # 使用仓库根 config.json
./mac-switch --config ~/my.json     # 使用其他配置
# 或后台运行:nohup ./mac-switch >/tmp/mac-switch.log 2>&1 &
```

注意:从终端运行时,「输入监控」权限挂在**你的终端 App**(如 iTerm)上,授权时勾选终端即可。

## 选项

| 选项 | 说明 |
| --- | --- |
| `--config <路径>` | 指定配置文件;相对路径按当前工作目录解析。默认 `<仓库根>/config.json`。 |
| `--keycode <数字>` | 临时覆盖配置里的热键键码(0...255),不写回文件。 |
| `--modifier <名称>` | 临时覆盖配置里的修饰键,如 `alt`、`cmd`、`alt+shift`。 |
| `--print-config` | 打印解析后的完整配置(含绝对路径与 `located` 是否找得到应用),用于排查配置问题。 |
| `--check` | 只打印「输入监控」「辅助功能」权限状态,不启动监听。 |
| `-h`, `--help` | 显示帮助。 |

排错第一步:

```bash
./mac-switch --print-config
```

它会告诉你配置从哪读的、`path` 解析成了什么、应用当前是否定位得到。

## 卸载

```bash
./uninstall.sh
```

会停掉进程、删除 LaunchAgent 与 `MacSwitch.app`,但**保留 `config.json`**。

## 从 ds-window-switch 迁移

本项目原名为 `ds-window-switch`,只支持在 IntelliJ IDEA 与 DeepSeek Harness 之间切换。改名与通用化后:

- 老的 `--idea` / `--harness` / `--harness-path` 参数已移除,改为在 `config.json` 的 `apps` 里配置(字段与示例见 [config.example.json](config.example.json))。
- 另外注意:旧版默认的 `dsh-electron` 在实际机器上可能根本解析不到应用 —— 用 Chrome「创建快捷方式」生成的 `DeepSeek Harness.app` 是 app-mode 外壳,其 bundleId 形如 `com.google.Chrome.app.<app_id>`。用 `plutil -extract CFBundleIdentifier raw -o - "$HOME/DeepSeek Harness.app/Contents/Info.plist"` 可读回真实值。
- 二进制 / 应用 / LaunchAgent 依次改名为 `mac-switch`、`MacSwitch.app`、`com.macswitch.agent`。`install.sh` 会自动清理旧版进程、`ds.window.switch` 服务与 `DSWindowSwitch.app`。
- **权限需要重新授予**:TCC 权限绑定签名身份,名称变化等于一个新程序。到 系统设置 里给 `MacSwitch` 重新勾选「输入监控」「辅助功能」,并移除旧的 `DSWindowSwitch` 条目。

## 常见问题

- **按下后目标应用仍弹出自己的 Switcher**:说明「辅助功能」权限缺失,按键未被拦截。重新运行后允许弹出的「辅助功能」请求即可。用 `./mac-switch --check` 可确认。
- **重新编译后失效**:TCC 权限绑定到签名身份,重编译后需重新授权一次(在 输入监控/辅助功能 中把 MacSwitch 勾掉再勾上)。
- **改了 config.json 没生效**:程序只在启动时读配置。用 `launchctl kickstart -k gui/$(id -u)/com.macswitch.agent` 重启。
- **启动即退出**:看 `/tmp/mac-switch.app.err.log`,通常是配置有问题(路径写错、bundle id 查不到、JSON 不合法),错误信息里会指出是哪个字段。
- **某个应用定位不到**:先用 `./mac-switch --print-config` 看 `located` 是否为 `false`。若应用没注册到系统,填 `path`;相对路径是相对配置文件所在目录。
