[English](README.md) | **中文**

# Chromium Fingerprint Browser v2 实验版

这是 `multi-profile-fingerprint-browser` 的独立 Chromium/CEF 线原型。

它不修改稳定的 WKWebView v1 主程序。当前实现是 Swift/AppKit 外壳，启动本机已安装的 Chromium 家族浏览器，并为每个 Profile 注入独立启动状态。后续真 CEF 嵌入时，可以替换 launcher 层，保留 profile、代理、导入导出和风险检测模型。

## 现在已经可用

- 每个 Profile 独立 Chromium `--user-data-dir`
- 每个 Profile 独立首页
- 每个 Profile 独立指纹预设：
  - User-Agent
  - `Accept-Language` / `--lang`
  - 通过 `TZ` 进程环境设置时区
  - 用于检测和一致性检查的屏幕预设
  - device scale factor
  - WebRTC IP policy
- Chromium 浏览器窗口大小不再每次启动强制覆盖；同一个 Profile 的 Chromium `user-data-dir` 会记住你上次调过的大小。
- 每个 Profile 独立代理启动参数：
  - 直连：`--no-proxy-server`
  - 跟随系统：不覆盖代理
  - HTTP：`--proxy-server=http://host:port`
  - SOCKS5：`--proxy-server=socks5://host:port`
- Profile 配置 JSON 导出 / 导入
- 使用保存的代理配置检测出口 IP
- 相同代理 / 相同上次出口 IP 风险提示
- 本地指纹检测页，会在该 Chromium Profile 里打开

## 现在还不是

- 不是魔改 Chromium fork
- 不做 TLS / JA3 / HTTP/2 指纹魔改
- 还不是 CEF 嵌入
- 不声称移动 Chrome 预设在桌面 Mac 上低风险

这一阶段的重点是把内核边界做实：v1 继续做诚实 WebKit；v2 负责 Chromium Profile 启动、代理和 user-data 隔离。

## 运行

```bash
swift build
swift run ChromiumFingerprintBrowser
```

App 会按顺序寻找这些浏览器：

- `/Applications/Chromium.app/Contents/MacOS/Chromium`
- `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
- `/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary`
- `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`
- `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge`

强制指定浏览器：

```bash
CHROMIUM_EXECUTABLE="/path/to/Chromium" swift run ChromiumFingerprintBrowser
```

## 打包

```bash
./packaging/make-app.sh
```

生成：

```text
dist/Chromium Fingerprint Browser v2.app
```

## 存储位置

Profile 配置和 Chromium 用户数据在：

```text
~/Library/Application Support/local.multi-profile-fingerprint-browser.chromium-v2/
```

每个 Profile 都有：

```text
profiles/<profile-id>/user-data/
```

这就是 v2 当前最重要的隔离边界。
