# SwitchProxy

一个常驻 macOS 菜单栏的「自动代理切换」小工具。

它在本地跑一个**固定监听端口**的中转代理（默认 `127.0.0.1:1087`），系统代理只需指向它一次；
当你在不同地点之间移动时，中转层会**根据当前网络自动切换上游代理**，全程无需再次输入管理员密码。

```
系统代理 ──固定指向──► 127.0.0.1:1087 (本地中转) ──转发──► 当前上游 (HTTP / SOCKS5 / 直连)
   应用也可直接用 ──► socks5h://127.0.0.1:1087        ▲
        (同一端口同时认 HTTP 和 SOCKS5)    网络变化时自动选择已绑定的上游
```

## 功能

- 纯菜单栏 App（无 Dock 图标，`LSUIElement`）
- **本地监听为 HTTP / SOCKS5 混合端口**（按首字节自动识别）：系统代理走 HTTP,需要 SOCKS 的应用直接指 `socks5h://127.0.0.1:端口`,同一端口即可
- 上游支持 **HTTP** 和 **SOCKS5**（均可带用户名/密码认证）
- 处理 HTTPS（`CONNECT` 隧道）与普通 HTTP；目标域名始终交由上游解析（远端 DNS,避免本地污染）
- **自动按网络切换**：把"当前网络"绑定到某个配置，之后到达该网络即自动启用
- 菜单内快速手动切换 / 直连
- **「管理代理」窗口**：集中添加、编辑、删除配置，并把当前网络绑定到所选配置
- **本地监听端口可配置**（在「管理代理」窗口里修改；改端口会自动重启中转，若系统代理已开启会自动重新指向新端口）
- **开机自启**（菜单内开关，基于 `SMAppService` 登录项）
- 一键「设为系统代理 / 取消系统代理」（写入所有启用的网络服务，单次管理员授权）
- 退出时若系统代理仍指向本中转，会自动取消，避免断网

## 网络识别方式

为每个网络计算一个标识：优先使用 Wi-Fi SSID（`wifi:名称`），取不到时回退到默认网关 IP（`gw:x.x.x.x`）。
> 注：较新版本 macOS 读取 SSID 需要"定位服务"权限；未授权时会自动使用网关 IP，同样能区分两个地点。

## 构建与运行

需要 Xcode 与 [XcodeGen](https://github.com/yonsm/XcodeGen)（`brew install xcodegen`）。

```bash
# 生成 Xcode 工程
xcodegen generate

# 命令行构建
xcodebuild -project SwitchProxy.xcodeproj -scheme SwitchProxy -configuration Release build

# 或直接用 Xcode 打开
open SwitchProxy.xcodeproj
```

构建产物 `SwitchProxy.app` 建议拖到 `/Applications` 再使用。

> **开机自启注意**：登录项注册的是当前 App 所在路径。请先把 App 放到 `/Applications`（或其它固定位置）再点「开机自启」，否则注册的会是临时构建目录。首次开启后可能需要在「系统设置 → 通用 → 登录项」里允许。

## 典型用法

1. 启动 App，点菜单栏图标 →「管理代理…」，在窗口里「添加」两个地点的上游代理（HTTP 或 SOCKS5）。
2. 在某地点时，于「管理代理」窗口选中对应配置，点「把当前网络绑定到所选」，把当前网络与该配置关联。
3. 打开「自动按网络切换」。
4. 点「设为系统代理」（输入一次管理员密码）。
之后在两地之间移动时会自动切换上游，系统代理始终指向本地中转、无需再改。

## 代码结构（`Sources/`）

| 文件 | 职责 |
| --- | --- |
| `main.swift` | 入口，设为 `.accessory`（仅菜单栏） |
| `AppDelegate.swift` | 组装各组件、自动切换协调 |
| `Models.swift` | `ProxyConfig` 模型与 `ConfigStore`（持久化 + 线程安全快照） |
| `ProxyRelay.swift` | 本地中转：混合端口监听（HTTP/SOCKS5 自动识别）、解析请求、转发到 HTTP/SOCKS5/直连、双向管道 |
| `Socks5.swift` | SOCKS5 客户端握手（连接上游时使用，含用户名/密码认证） |
| `NetworkMonitor.swift` | 监听网络变化、计算网络标识（SSID / 网关） |
| `SystemProxy.swift` | 通过 `networksetup` 配置/取消系统代理 |
| `MenuController.swift` | 菜单构建与所有菜单动作（含开机自启、改端口协调） |
| `ProxyManagerWindowController.swift` | 「管理代理」窗口：端口设置 + 配置列表 + 增删改 + 绑定网络 |
| `ConfigEditor.swift` | 添加/编辑配置的表单 |
| `LaunchAtLogin.swift` | 开机自启（`SMAppService` 登录项）封装 |

## 已知限制

- 普通 HTTP（非 HTTPS）经 SOCKS5/直连时会强制 `Connection: close`（每连接一个请求），HTTPS 不受影响。
- 配置（含明文密码）保存在 `UserDefaults`；如需更高安全性可改用 Keychain。
- App 未做 Developer ID 签名/公证，首次运行可能需在「系统设置 → 隐私与安全性」放行。
