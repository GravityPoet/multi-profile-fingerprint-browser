[English](README.md) | **中文**

# 多账号隔离指纹浏览器 (Multi-Profile Fingerprint Browser)

一个 macOS 上免费、开源的指纹隔离浏览器。每个账号空间一套独立的 Cookie / 存储 / 浏览器指纹，让远端看到的是不同的设备 + 不同的用户。

旨在打破 Multilogin / GoLogin / AdsPower 等付费 anti-detect 浏览器的垄断，提供同等核心能力的本地、零订阅替代品。

## 现状

- macOS 12+，Swift + WKWebView 单文件实现，约 3000 行
- 已可用，处于 0.1.0 早期阶段。还在迭代抗检测细节
- 仅 macOS，暂无 Windows / Linux 计划

## 核心能力

### 账号空间隔离
- 多 Profile，各自独立 Cookie / localStorage / IndexedDB / 缓存（macOS 14+ 用 `WKWebsiteDataStore(forIdentifier:)`，macOS 12-13 共享默认 Store）
- 每个 Profile 可设独立首页
- Cookie JSON 导入 / 导出
- 一键清空当前账号空间全部数据

### 指纹层
- 5 个内置预设：MacBook Air 13, MacBook Pro 14, iMac 5K, iPad 13, iPhone 15 Pro
- 一键随机化（70% Mac / 20% iPad / 10% iPhone 加权）
- Per-Profile 指纹独立持久化
- 覆盖：UserAgent、`navigator.platform/language/languages/hardwareConcurrency/deviceMemory/maxTouchPoints`、`screen.*`、`devicePixelRatio`、`Intl.DateTimeFormat` 时区、`Date.prototype.getTimezoneOffset`、`screen.orientation`

### 抗检测层（增强隐私）
- Canvas `getImageData / toDataURL / toBlob` 像素级 stable-seed 噪声
- WebGL `getParameter`（UNMASKED_VENDOR / RENDERER 伪装）+ `readPixels` 噪声
- AudioBuffer `getChannelData` + AnalyserNode `getFloatFrequencyData` 浮点噪声
- `navigator.userAgentData / plugins / mimeTypes / mediaDevices` 中和
- `permissions.query` 永远返回 `prompt`
- `matchMedia` hover / pointer / any-pointer 跟随触屏指纹
- `Function.prototype.toString` 修补：所有 hook 函数返回 `function NAME() { [native code] }` 标准格式，过 toString 检测
- 全部 hook 命名化（不是匿名箭头），过名字检测

### 隐私层
- WebRTC 全栈关闭（`RTCPeerConnection` 等设为 `undefined`，`enumerateDevices` 返回空），防 STUN 真实 IP 泄露
- Global Privacy Control = true

### 浏览器基础
- 多标签（OS 级窗口聚合）
- 历史前进后退、刷新、缩放、查找
- 任意 https 首页
- 内置指纹检测页（菜单栏 → 隐私 → 指纹检测）

## 已知限制 / 与商业产品差距

诚实写出来。如果是高对抗场景（Fortune 500 反欺诈、Cloudflare 高难度 Turnstile、专业指纹库 fingerprint.com 企业版），现状不一定能稳过。

- **TLS / JA3 / JA4 指纹**：未做。系统 `URLSession` / WKWebView 的 TLS ClientHello 由 macOS 内核决定，无法在用户态改写。商业产品多用魔改 Chromium。
- **HTTP/2 帧顺序、ALPS、HTTP/3 指纹**：未做。同上。
- **WebRTC 真 IP 泄露**：通过禁用 WebRTC API 来防。如果业务必须 WebRTC，本工具不适合。
- **`window.outerWidth / outerHeight`**：未改写。Mac 窗口真实尺寸暴露。和 `screen.width=393`（iPhone 预设）会有矛盾。这是为了保留可用的 Mac 窗口尺寸做的取舍。
- **CSS `device-width / orientation` media query**：部分覆盖（hover/pointer），完整尺寸 media 未改写。
- **Web Worker / iframe 隔离上下文**：注入用 `forMainFrameOnly: false` 已覆盖 iframe；Worker 上下文是否同样注入待验证。
- **macOS 12 / 13**：`WKWebsiteDataStore` 不支持 per-identifier，多 Profile 共享默认 Store 退化为"只有指纹区分，不隔离 Cookie"。建议 macOS 14+。
- **iOS 设备预设（iPhone / iPad）**：UA + screen 可换，但 safe-area-inset、字体列表、`window.matchMedia` 的部分 viewport 查询会穿帮。Mac 预设更稳。

如果你做的是中低对抗场景（注册多个普通 SaaS、防止站点行为追踪、防止跨站设备识别、个人多账号工作流），现状的隔离强度通常够用。

## 与商业 anti-detect 浏览器的对比

| 能力 | 本项目 | Multilogin/GoLogin |
|---|---|---|
| 多 Profile 隔离 | ✅ | ✅ |
| Canvas/WebGL/Audio 噪声 | ✅ | ✅ |
| UA / 屏幕 / 时区伪装 | ✅ | ✅ |
| 指纹随机化 | ✅ | ✅ |
| WebRTC 关闭 | ✅ | ✅ |
| `toString` 检测防御 | ✅ | ✅ |
| TLS / JA3 指纹 | ❌ | ✅ |
| HTTP/2 fingerprint | ❌ | ✅ |
| 真 Chromium 内核 | ❌ (WKWebView) | ✅ |
| 价格 | 0 元 | $99/月起 |

## 构建

```bash
swift build -c release
# 或打包成 .app
./packaging/make-app.sh
# 打包 DMG
./packaging/make-dmg.sh
```

需要 Xcode Command Line Tools。

## 设计选择

- **WKWebView 而不是 Chromium 内核**：单文件 Swift、零依赖、二进制小。代价：无法改 TLS 指纹、无法改 HTTP/2 帧。对个人多账号场景够用。
- **本地配置，无云端**：UserDefaults + Codable，所有数据在你的机器上。
- **指纹基于 stable seed**：同 Profile 多次启动 Canvas/WebGL/Audio 噪声一致，避免"每次刷新指纹都变"的反追踪信号。

## 路线图

- [ ] HTTP 头 `Accept-Language` / `Sec-CH-UA` 子请求覆盖（不只主请求）
- [ ] `screen` getter 通过 Object.defineProperty on Worker scope（如果 WKWebView 允许）
- [ ] Per-Profile 代理设置（HTTP / SOCKS5）
- [ ] 指纹模板导入导出（社区共享）
- [ ] Profile 备份 / 恢复（已有 Cookie 导出 + 指纹导出框架，未完整端到端）

## License

MIT。

## 关联项目

- [chatgpt-web-desktop](https://github.com/GravityPoet/chatgpt-web-desktop) — 本项目的前身，专注 ChatGPT macOS 客户端。该项目把指纹浏览器部分拆出来独立维护。
