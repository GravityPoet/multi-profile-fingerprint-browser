[English](README.md) | **中文**

# 多账号反检测浏览器

免费、开源、macOS 原生的多账号反检测浏览器。每个 Profile 都会启动一个完全隔离的 Camoufox（Firefox patched）实例，拥有独立指纹、代理、Cookie 与本地存储。目标是给个人多账号工作流提供一个零订阅的 Multilogin / GoLogin / AdsPower 替代方案。

`v1.2.0` 是一次完整重写。旧的 WKWebView 隐私壳版本保留在 `legacy-wkwebview-cef` 分支。

## 1.2.0 变化

| | v1.1 (WKWebView) | v1.2.0 (Camoufox) |
|---|---|---|
| 浏览器内核 | macOS WKWebView | Camoufox v150 (Firefox patched) |
| TLS / JA3 / JA4 指纹 | 不修改 | 继承 Firefox + NSS |
| HTTP/2 帧顺序 / ALPS | 不修改 | 继承 Firefox |
| Canvas / WebGL / Audio 噪声 | JS hook | Camoufox C++ patch |
| `navigator.*` 伪装 | JS hook，可被 toString 检测 | 二进制层，非 JS hook |
| Per-profile proxy | best-effort | Firefox `network.proxy.*` prefs |
| UA → 屏幕 → 时区一致性 | 仅 mac/iOS 家族 | 内置 v150 预设库 |

这是第一个可以在中等对抗场景下接近商业 anti-detect browser 使用方式的版本。

## 工作方式

1. 首次使用时，App 会下载 Camoufox v150（约 300 MB）到：
   `~/Library/Application Support/MultiProfileFingerprintBrowser/runtime/`
   下载包会做 SHA256 校验。
2. 每个 Profile 以 `profiles/<uuid>/meta.json` 持久化。
3. 点击 **Launch** 时，App 会：
   - 写入 per-profile Firefox `user.js`，包括代理、语言和 Marionette 设置。
   - 把指纹 JSON 编码并切成 `CAMOU_CONFIG_1..N` 环境变量。
   - 使用 `--profile <dir> --no-remote --new-instance` 启动 Camoufox。
4. Camoufox 启动时读取环境变量，在 C++ 层应用指纹，并把所有运行数据写入独立 profile 目录。

Swift 壳应用不在网页运行时注入 JS hook；真正的伪装逻辑都在 patched browser binary 内完成。

## 功能

### Profile 隔离

- 每个 Profile 独立 Firefox profile 目录：`firefox-profile/`
- 独立 Cookie、localStorage、IndexedDB、缓存、历史记录
- Firefox 兼容书签与扩展随 profile 隔离
- 多个 Profile 可同时打开多个独立窗口

### 指纹伪装（Camoufox）

- User Agent + `navigator.platform / oscpu / appVersion`
- `navigator.language / languages` + Firefox `intl.accept_languages`
- `navigator.hardwareConcurrency / deviceMemory / maxTouchPoints`
- `screen.width / height / availWidth / availHeight / colorDepth`
- `window.devicePixelRatio`
- `Intl.DateTimeFormat` timezone + `Date.prototype.getTimezoneOffset`
- WebGL `vendor / renderer`
- Canvas / WebGL / Audio 噪声（二进制 patch，不是 JS hook）

### 内置预设

内置 7 组 OS × browser 组合：

- macOS 14 Intel / Apple Silicon（en-US、ja-JP）
- Windows 10 / Windows 11（en-US、en-GB、zh-CN）
- Linux x86_64（en-US）

可以从下拉框选择，也可以点击 **Randomize** 随机抽取。

### 代理

- Direct、HTTP、SOCKS5
- Per-profile Firefox 代理 prefs，不依赖系统代理
- SOCKS5 强制 `network.proxy.socks_remote_dns=true`，避免本机 DNS 泄露
- 1.2.0 会保存用户名/密码字段，但还没有自动注入代理认证；需要代理侧免认证或由 Firefox 交互处理认证

### Marionette

- 每个 Profile 可单独开启
- 端口从 2828 起自动分配，避免冲突
- 给 Phase 2/后续自动化接 Playwright、Selenium 或 Marionette 协议使用

## 与商业产品的诚实对比

| 能力 | 本项目 v1.2.0 | Multilogin / GoLogin / AdsPower |
|---|---|---|
| 多 Profile 隔离 | 是 | 是 |
| Canvas / WebGL / Audio 噪声 | 是（二进制层） | 是 |
| UA / 屏幕 / 时区伪装 | 是 | 是 |
| TLS / JA3 / JA4 指纹 | Firefox baseline | 定制 Chromium |
| HTTP/2 fingerprint | Firefox baseline | 是 |
| `toString` 检测防御 | 是（二进制层，非 JS hook） | 是 |
| Per-profile proxy | 是 | 是 |
| 云端 Profile 仓库 | 否 | 是 |
| 团队协作 / 批量农场 | 否 | 是 |
| iPhone / iPad 移动预设 | 否，延后到 1.3 | 是 |
| 价格 | 0 元 | $99/月起 |

适合单机 Mac 上的个人多账号工作流。如果你需要云同步、团队协作、托管浏览器农场或 100+ 并发 profile，仍然应该用商业产品。

## 本项目不做什么

- 不做 Chromium 内核。Camoufox 是 Firefox-based；需要 Chrome/WebKit-only 的网站会看到 Firefox UA，这是设计选择。
- 不做云端 profile vault、团队空间、浏览器农场租用。
- 目前不做 Windows / Linux host app。Camoufox 本身跨平台，但这个 Swift 壳只支持 macOS。
- 1.2.0 不做 iPhone / Android 设备模拟。移动预设会等触控输入、方向和 viewport 一致性收束后进入 1.3。

## 构建

```bash
swift build -c release          # SPM 构建
./packaging/make-app.sh         # 打包 .app
./packaging/make-dmg.sh         # 生成带 /Applications 链接的 DMG
```

要求：

- macOS 12+
- Xcode Command Line Tools
- Apple Silicon (`arm64`)；Intel Mac host support 进入 1.2.x

首次启动会下载一次 Camoufox v150（约 300 MB），之后复用本地缓存。

## 架构

```
Sources/MultiProfileFingerprintBrowser/
├── main.swift                   AppKit 入口，MPFB_SMOKE=1 时切到 SmokeTest
├── AppDelegate.swift            NSWindow + SwiftUI RootView
├── Localization.swift           中英文字符串 helper
├── Models/
│   ├── Profile.swift            id、name、fingerprint、proxy、notes
│   ├── Fingerprint.swift        Camoufox dotted-key map + JSON encode
│   └── ProxyConfig.swift        Direct / HTTP / SOCKS5 + Firefox prefs
├── Managers/
│   ├── AppPaths.swift           ~/Library/Application Support 布局
│   ├── ProfileStore.swift       磁盘 CRUD
│   ├── FingerprintPresets.swift 内置 v150 预设库
│   ├── PortAllocator.swift      Marionette 端口分配（2828+）
│   ├── CamoufoxRuntime.swift    下载 / SHA256 / 解压
│   └── CamoufoxLauncher.swift   user.js + CAMOU_CONFIG_N + Process.run()
├── Util/
│   ├── SHA256.swift             流式 SHA256
│   ├── Logger.swift             OSLog + stderr
│   └── ZipExtractor.swift       /usr/bin/unzip wrapper
├── ViewModels/AppState.swift    @MainActor ObservableObject
└── Views/                       SwiftUI 前端

Resources/fingerprint-presets-v150.json   7 组手工策划预设
```

## 路线图

- [x] 1.2.0 — Camoufox engine、真实指纹伪装、per-profile proxy
- [ ] 1.2.x — Intel Mac (`x86_64`) host support
- [ ] 1.3 — 移动预设（iPhone/iPad）、Camoufox v151 sync
- [ ] 1.4 — Profile 导入/导出、指纹预设分享
- [ ] 1.5 — Headless / Playwright 自动化示例

## License

MIT。

## Credits

- [Camoufox](https://github.com/daijro/camoufox) — 本项目驱动的 Firefox patched anti-detect browser，MPL-2.0。
- v1.1 (WKWebView) 已保留在 `legacy-wkwebview-cef` 分支。
