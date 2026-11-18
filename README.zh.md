# Samsung Dumb Monitor

[English](README.md)

`天晓得这些几大千的聪明显示器为什么连DDC/CI都没有。`

一个很小的原生 macOS 菜单栏工具，附 Swift API 和 CLI。
可以切输入源、开机／待机、调音量、静音、调亮度。

**只走本地 LAN**，不用登录三星账号，不依赖 SmartThings App，
不用给 Cloud API 付钱，也不用操心 PAT 过期。首次在显示器上允许配对，
本地 token 和证书指纹保存在 macOS 钥匙串中。
需要兼容设备启用 IP Remote；面向 ViewFinity S9 开发，不保证所有三星显示器兼容。

## 构建和使用

从 [Releases](../../releases) 下载适合你的 Mac 的 DMG，打开后将 `Dumb Monitor.app` 拖入“应用程序”（macOS 14+）。若 macOS 阻止打开，在终端运行：

```sh
xattr -dr com.apple.quarantine "/Applications/Dumb Monitor.app"
```

或使用 Swift 6／Xcode 16 或更新版本从源码构建，无第三方依赖。

```sh
./build.sh
swift test -c release
```

本地构建会自动使用钥匙串中唯一的 Apple Development 身份。也可将 `CODE_SIGN_IDENTITY` 设为固定的 Apple 代码签名身份，让 macOS 在升级后识别 App 并保留辅助功能授权。

打开 `Dumb Monitor.app`（源码构建版本在 `build/` 目录），输入显示器的局域网地址，在显示器上允许配对。

键盘控制需要辅助功能权限。
音量键默认跟随所选音频输出。可在设置中开启「使用非 USB-C 输入源时也控制显示器音量」，这样显示器连接到 Mac 并显示 DisplayPort 等其他输入时，音量键也能控制它。亮度键跟随活动显示器。

输入源、开机和待机均可绑定快捷键。App 默认在切输入源前先发送 `powerOn`（可关闭），只等命令响应，不额外轮询或延时。

媒体快捷键用于在锁屏时切换输入源和控制电源。

支持隐藏图标、隐藏开机启动、音量上限和整数步进。

CLI 复用 App 的配对，也可以在终端配对（`monitor.local` 为示例，请替换）：

```sh
./build/s9-input pair monitor.local
./build/s9-input status
./build/s9-input power-status
./build/s9-input power-on
./build/s9-input power-off
./build/s9-input usb-c
./build/s9-input displayport
./build/s9-input input HDMI1  # 仅为兼容 HDMI 设备的示例
./build/s9-input volume 20
./build/s9-input mute
./build/s9-input unmute
./build/s9-input brightness 25
./build/s9-input --help
```

## 实际指令

通过 HTTPS **1516** 端口发送 JSON-RPC，固定显示器证书：

```json
{"jsonrpc":"2.0","id":"1","method":"inputSourceControl","params":{"AccessToken":"<local-token>","inputSource":"USB-C"}}
```

| 方法 | 设置参数 |
| --- | --- |
| `powerControl` | `power`：`powerOn` 或 `powerOff` |
| `inputSourceControl` | `inputSource`：`USB-C`、`Display Port` 或配置的准确协议值 |
| `directVolumeControl` | `volume`：0–100 |
| `muteControl` | `mute`：`muteOn` 或 `muteOff` |
| `backlightControl` | `backlight`：0–50 |

CLI 的输入指令保持直接切换，需要时先执行 `power-on`。

省略设置参数即读取。配对先调用 `getTVStates`，再调用 `createAccessToken`。
不模拟遥控菜单。这是非官方接口，固件更新可能影响兼容性。

## 卸载

卸载时，先在设置中选择 **“清除本机数据并退出…”**，再将 App 拖进废纸篓。
它会关闭开机启动，删除设置、缓存及与 CLI 共用的配对凭证。
辅助功能／防火墙条目、另存的 CLI 和凭证备份需自行删除；不会撤销显示器端授权。

## 许可

[MPL-2.0](LICENSE)。欢迎集成进商业应用；希望这些显示器控制功能不设付费解锁。项目与三星无隶属关系。
