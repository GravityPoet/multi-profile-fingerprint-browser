[English](README.md) | **中文**

# Chromium Fingerprint Browser v2 实验版

这是 `multi-profile-fingerprint-browser` 的独立 Chromium/CEF 线。

它不修改稳定的 WKWebView v1 主程序。当前实现是 Swift/AppKit 外壳 + 随 app 打包的 CEF/Chromium 浏览器组件；打开 Profile 时不再启动系统 Chrome。

## 现在已经可用

- 每个 Profile 独立 CEF `root_cache_path` / `cache_path`
- 每个 Profile 独立 cache / cookies / localStorage
- 每个 Profile 独立首页
- 每个 Profile 独立指纹预设：
  - User-Agent
  - `Accept-Language` / `--lang`
  - 通过 `TZ` 进程环境设置时区
  - 用于检测和一致性检查的屏幕预设
  - device scale factor
  - WebRTC IP policy
- CEF 浏览器窗口按 Profile 保存上次边界，不再每次固定成同一个大小
- 每个 Profile 启动自己的 CEF 进程并应用独立代理：
  - 直连：CEF `no-proxy-server`
  - 跟随系统：不覆盖代理
  - HTTP：CEF `proxy-server=http://host:port`
  - SOCKS5：CEF `proxy-server=socks5://host:port`
- Profile 配置 JSON 导出 / 导入
- 使用保存的代理配置检测出口 IP
- 相同代理 / 相同上次出口 IP 风险提示
- 本地指纹检测页，会在该 CEF Profile 里打开

## 现在还不是

- 不是魔改 Chromium fork
- 不做 TLS / JA3 / HTTP/2 指纹魔改
- 不是 Electron
- 不启动系统 Chrome / Chromium
- 不声称移动 Chrome 预设在桌面 Mac 上低风险

这一阶段的重点是把内核边界做实：v1 继续做诚实 WebKit；v2 负责 CEF/Chromium Profile、代理和数据目录隔离。

## 运行

```bash
swift build
swift run ChromiumFingerprintBrowser
```

直接 `swift run` 只运行 Swift 外壳。要打开网页，需要先构建 CEF 组件；打包脚本会自动完成。

开发时强制指定 CEF 组件：

```bash
MPFB_CEF_EXECUTABLE="/path/to/ChromiumFingerprintCEF" swift run ChromiumFingerprintBrowser
```

## 打包

```bash
./packaging/make-app.sh
```

生成：

```text
dist/Chromium Fingerprint Browser v2.app
```

第一次打包会从 CEF 官方自动构建服务器下载 macOS CEF binary，并放在 `cef/third_party/`。该目录不进入 Git。

## 存储位置

Profile 配置和 CEF 用户数据在：

```text
~/Library/Application Support/local.multi-profile-fingerprint-browser.chromium-v2/
```

每个 Profile 都有：

```text
profiles/<profile-id>/user-data/
profiles/<profile-id>/cef-window-bounds.txt
```

这就是 v2 当前最重要的隔离边界。
