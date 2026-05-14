[English](README.md) | **中文**

# 多账号隔离指纹浏览器 (Multi-Profile Fingerprint Browser)

一个 macOS 上免费、开源的 Safari/WebKit 家族一致性隐私指纹浏览器。每个账号空间一套独立的 Cookie / 存储 / 稳定 Safari 设备指纹，目标是减少跨账号、跨站点的指纹关联。

它不是“真 anti-detect 浏览器”，也不能补齐 TLS / HTTP/2 / Chromium 内核级指纹。它的定位是本地、零订阅、低异常的多账号隐私浏览器：只伪装成不同 Safari/WebKit 设备，不假装 Chrome / Firefox。

## 现状

- macOS 12+，Swift + WKWebView 单文件实现，约 4500 行
- `v0.1.0` 已作为稳定 WKWebView 基线保留
- 当前线是 `v1.1`：Safari/WebKit 隐私增强版，重点是稳定、好用、诚实、低异常
- 仅 macOS，暂无 Windows / Linux 计划

## 版本线

- **v1：Safari/WebKit 隐私隔离版** — 当前仓库。做 Safari/WebKit 家族低异常多空间隔离，不收订阅费，也不声称能补 Chromium/TLS 级指纹。
- **v2：Chromium/CEF 实验版** — 已作为独立 [`chromium-v2`](chromium-v2/README.zh-CN.md) 子项目落地。这条线负责更干净的 per-profile proxy 和 Chromium user-data 隔离。

## 核心能力

### 账号空间隔离
- 多 Profile，各自独立 Cookie / localStorage / IndexedDB / 缓存（macOS 14+ 用 `WKWebsiteDataStore(forIdentifier:)`，macOS 12-13 共享默认 Store）
- 每个 Profile 可设独立首页
- Cookie JSON 导入 / 导出
- 一键清空当前账号空间全部数据

### 指纹层
- 5 个内置预设：MacBook Air 13, MacBook Pro 14, iMac 5K, iPad 13, iPhone 15 Pro
- 一键随机化默认生成 Mac Safari 稳定指纹；iPhone/iPad 作为显式预设保留，因为大 Mac 窗口下移动预设风险更高
- Per-Profile 指纹独立持久化
- 每个 Profile 固定时区，按主语言解析（例如 `en-US` 映射美国时区，`zh-CN` 映射 `Asia/Shanghai`）
- 一致性检查覆盖 UA 家族、语言/时区、屏幕尺寸、触控能力和移动预设窗口风险
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
- 每个 Profile 独立 WebRTC 防护（开启时 `RTCPeerConnection` 等设为 `undefined`，`enumerateDevices` 返回空），防 STUN 真实 IP 泄露
- Global Privacy Control = true

### Profile 备份 / 恢复
- Profile 配置导出 / 导入覆盖：名称、首页、指纹、固定时区、增强隐私、WebRTC 防护和代理映射
- Cookie 继续单独导入 / 导出
- 不承诺完整克隆 `WKWebsiteDataStore`，因为它跨 WebKit/macOS 版本不够稳定

### 代理映射 / 出口 IP 检测
- 每个 Profile 可保存代理映射：直连、跟随系统、HTTP、SOCKS5
- App 可用 `URLSession` 检测该配置的出口 IP、国家和 ASN/组织
- 多个 Profile 使用相同代理映射或上次检测到相同出口 IP 时会提示风险
- WKWebView v1 **不保证**干净的 per-profile proxy 强制接管；建议把 `127.0.0.1:18001` 这类本地入口背后接到 `sing-box`、Clash、Surge、VPS SOCKS5 或住宅代理

### 浏览器基础
- 多标签（OS 级窗口聚合）
- 历史前进后退、刷新、缩放、查找
- 本地起始页，不自动联网，可输入网址或搜索
- 任意 https 首页
- 内置指纹检测页 + 风险概览（菜单栏 → 隐私 → 指纹检测）

## 已知限制 / 与商业产品差距

诚实写出来。如果是高对抗场景（Fortune 500 反欺诈、Cloudflare 高难度 Turnstile、专业指纹库 fingerprint.com 企业版），现状不一定能稳过。

- **TLS / JA3 / JA4 指纹**：未做。系统 `URLSession` / WKWebView 的 TLS ClientHello 由 macOS 内核决定，无法在用户态改写。商业产品多用魔改 Chromium。
- **HTTP/2 帧顺序、ALPS、HTTP/3 指纹**：未做。同上。
- **WebRTC 真 IP 泄露**：通过禁用 WebRTC API 来防。如果业务必须 WebRTC，本工具不适合。
- **`window.outerWidth / outerHeight`**：未改写。Mac 窗口真实尺寸暴露。和 `screen.width=393`（iPhone 预设）会有矛盾。这是为了保留可用的 Mac 窗口尺寸做的取舍。
- **CSS `device-width / orientation` media query**：部分覆盖（hover/pointer），完整尺寸 media 未改写。
- **Web Worker / iframe 隔离上下文**：内置指纹检测页会检测 iframe 值。Worker 也会检测；如果 Worker 可观察值与主页面指纹不一致，会明确显示“Worker 暴露不可控”。
- **WKWebView per-profile proxy**：v1 只保存代理映射，并可用 `URLSession` 检测该配置；不声称 WKWebView 已被干净地 per-profile 强制代理。
- **macOS 12 / 13**：`WKWebsiteDataStore` 不支持 per-identifier，多 Profile 共享默认 Store 退化为"只有指纹区分，不隔离 Cookie"。建议 macOS 14+。
- **iOS 设备预设（iPhone / iPad）**：UA + screen 可换，但 safe-area-inset、字体列表、`window.matchMedia` 的部分 viewport 查询会穿帮。Mac 预设更稳。

如果你做的是中低对抗场景（多个普通 SaaS 账号、减少站点行为追踪、防止跨站设备识别、个人多账号工作流），现状的隔离强度通常够用。高强度风控场景不要把它当成商业 anti-detect 浏览器替代品。

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

- [x] v1.1 时区策略和一致性检查
- [x] v1.1 iframe / Worker 检测覆盖
- [x] v1.1 Profile 配置备份 / 恢复
- [x] v1.1 代理映射与出口 IP 检测面板
- [x] v2 CEF/Chromium 子项目：随 app 打包 runtime，独立 `root_cache_path` / `cache_path`、代理映射、IP 检测和本地指纹检测页
- [ ] HTTP 头 `Accept-Language` / `Sec-CH-UA` 子请求覆盖（不只主请求）
- [x] 把 v2 launcher 层替换成嵌入式 CEF
- [ ] 指纹模板导入导出（社区共享）

## License

MIT。

## 关联项目

- [chatgpt-web-desktop](https://github.com/GravityPoet/chatgpt-web-desktop) — 本项目的前身，专注 ChatGPT macOS 客户端。该项目把指纹浏览器部分拆出来独立维护。
