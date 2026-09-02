# ds-window-switch

持续监听 **alt(⌥)+tab**:按下 alt+tab 即在两个应用之间切换窗口;两个应用都不在前台时,先切换到 **DeepSeek Harness**。

## 原理

用 macOS 的 CGEventTap(会话级键盘事件钩子)监听纯 `alt(⌥)+tab` 的 keyDown:

- 前台应用是 IDEA → 激活 DeepSeek Harness;
- 前台应用是 DeepSeek Harness → 激活 IDEA;
- 其他应用(或两者都不在前台)→ 先激活 DeepSeek Harness。

无外部依赖,仅使用系统自带的 `swiftc` 编译。

## 快速安装(推荐:登录后自动常驻)

```bash
# 进入本仓库目录后执行(脚本内部自行定位自身目录,路径均为相对路径,仓库放哪都能用)
cd ~/mac-switch
./install.sh
```

install.sh 会:编译 → 打包为 `DSWindowSwitch.app`(带 bundle,保证授权弹窗可靠出现)→ ad-hoc 签名 → 注册 LaunchAgent(`ds.window.switch`)并通过 `open` 启动该 app。

**首次运行需要依次授予两个权限**(每次授权后重启它一次):

1. 屏幕会弹出「输入监控」授权请求(应用名:**DSWindowSwitch**),允许,然后执行:

```bash
launchctl kickstart -k gui/$(id -u)/ds.window.switch
```

2. 接着弹出「辅助功能」授权请求,再允许,再次执行上面的 kickstart。

然后到 IDEA 里按 alt+tab,应立即跳到 DeepSeek Harness;再按一次跳回 IDEA。

若弹窗没出现:到 `系统设置 > 隐私与安全性 > 输入监控 / 辅助功能`,点 `+` 手动添加本仓库根目录下的 `DSWindowSwitch.app`(即 `./DSWindowSwitch.app`,用它的完整路径)。

日志:程序本体 `/tmp/ds.window.switch.app.out.log`、`/tmp/ds.window.switch.app.err.log`;launchd/open 层 `/tmp/ds.window.switch.out.log`、`/tmp/ds.window.switch.err.log`。

## 前台手动运行(调试用)

```bash
./ds-window-switch
# 或后台运行:nohup ./ds-window-switch >/tmp/ds-window-switch.log 2>&1 &
```

注意:从终端运行时,「输入监控」权限挂在**你的终端 App**(如 iTerm)上,授权时勾选终端即可。

检查权限状态(不触发弹窗):

```bash
./ds-window-switch --check
```

## 选项

| 选项 | 说明 | 默认值 |
| --- | --- | --- |
| `--idea <bundle-id>` | IDEA 的 bundle identifier | `com.jetbrains.intellij`(Ultimate;CE 版用 `com.jetbrains.intellij.ce`) |
| `--harness <bundle-id>` | DeepSeek Harness 的 bundle identifier | `dsh-electron` |
| `--harness-path <路径>` | Harness.app 路径(未注册到系统时用于启动它;支持绝对路径、`~/` 开头路径,以及相对仓库根的相对路径) | `../DeepSeek Harness.app`(相对仓库根 = 仓库同级) |
| `--keycode <数字>` | 切换键的虚拟键码 | `48`(Tab) |
| `--modifier <名称>` | 修饰键:ctrl / alt / cmd / shift | `alt`(⌥ Option) |
| `--check` | 只检查权限,不启动监听 | - |

改默认路径:编辑 `ds-window-switch.swift` 顶部的配置(默认值 `../DeepSeek Harness.app` 按可执行文件位置推导仓库根后解析),或直接编辑 `install.sh` 生成前重新编译。

## 卸载

```bash
./uninstall.sh
```

## 常见问题

- **按下后 IDEA 仍弹出 Switcher**:说明「辅助功能」权限缺失,按键未被拦截。重新运行后允许弹出的「辅助功能」请求即可。
- **重新编译后失效**:TCC 权限绑定到签名身份,重编译后需重新授权一次(在 输入监控/辅助功能 中把 DSWindowSwitch 勾掉再勾上)。
- **授权弹窗没出现**:手动到 `系统设置 > 隐私与安全性 > 输入监控 / 辅助功能` 用 `+` 添加 `DSWindowSwitch.app`。
- **换了 IDEA 版本**(CE/Ultimate):用 `--idea` 指定对应 bundle id,或修改源码顶部默认值。
- **Harness.app 移动了位置**:默认按「仓库的上一级」查找(相对仓库根);若放在别处(如 `/Applications`),用 `--harness-path` 指定新路径(绝对或 `~/` 开头),或改源码默认值。
