# 拾影 1.1.4 / PickVideo

一个在本机运行的 macOS 视频下载器。SwiftUI 界面，yt-dlp 解析与下载，FFmpeg 合并音视频。

## 下载与安装

从 [GitHub Releases](https://github.com/XuanLIN0224/PickVideo/releases/latest) 下载 DMG 或 ZIP。支持 **Apple Silicon Mac、macOS 14+**，当前不提供 Intel、Windows 或 Linux 应用。

打开 DMG，将“拾影”拖到 Applications。当前安装包包含解析引擎，但需要另外安装 FFmpeg、Node 和 aria2。已有 [Homebrew](https://brew.sh/) 时可以运行：

```sh
brew install ffmpeg node aria2
```

此版本使用 ad-hoc 签名，尚未获得 Apple Developer ID 签名和 Apple 公证。首次打开说明、依赖安装和下载校验见 [安装指南](docs/INSTALL.zh-CN.md)。版本改动见 [1.1.4 发布说明](docs/releases/v1.1.4.md)。

## 使用

1. 打开“应用程序”中的 **拾影**。
2. 需要账号权限时，进入“账号与设置”：Bilibili 可在内置官方网页扫码；YouTube 和其他网站可选择已登录的 Chrome、Edge、Firefox、Brave 或 Safari，也可导入 Netscape 格式的 cookies.txt。
3. 粘贴视频播放页链接或分享文字，点击“解析链接”。
4. 选择明确标注分辨率、来源档位和帧率的画质（例如 1080p 高码率 · 29.97 fps、4K · 2160p · 60 fps），或“指定格式”查看编码和码率；下方同时显示视频和音轨合计的预计大小。
5. 加入队列，下载完成后直接打开或在 Finder 显示文件。

默认保存在 `~/Downloads/拾影`。多个链接可以分行粘贴；先解析第一条，再选择批量加入队列。整个播放列表和正在进行的直播暂不支持。

## 登录与本地数据

- Bilibili 登录网页使用隔离、非持久的 WebKit 会话。登录窗口同时监听 Cookie、导航回跳，并每秒检查本机登录状态；收到有效状态后通过 Bilibili 官方接口核验并显示昵称。通知遗漏或回跳中断也会继续检测，核验暂时失败会自动重试。Bilibili 与 biligame 的官方跨域回跳保留在应用内，不交给 Safari。只有该站 Cookie 会保存到 macOS 钥匙串，账号名为 `bilibili`，服务名为 `app.pickvideo.credentials`。
- 更新后 macOS 可能再次确认钥匙串访问。读取与保存登录状态在后台进行；等待期间界面仍可操作，取消后的临时文件会清理。
- 下载时生成权限为 0600 的临时 Cookie 文件，子进程结束后删除。导入的 Cookie 文件不会被改写。
- 刚解析出的完整格式信息在内存中保留最多两分钟，视频链接和登录来源必须相同才会复用，避免点击下载时再次请求网页。下载所需的临时信息文件权限同为 0600，任务停止后删除；信息不写入历史，退出即失效。更换 Bilibili 账号会清除复用信息。
- 选择浏览器登录来源后，yt-dlp 在本机读取该浏览器 Cookie，访问相应的网站。默认访客模式不会读取浏览器 Cookie。
- 不运行 Web 服务，不把账号交给额外的解析网站。媒体请求直接访问来源网站。
- 队列与历史位于 `~/Library/Application Support/PickVideo/history.json`；更新过的引擎位于该目录下的 `bin/yt-dlp`。
- 退出会停止任务并保留分片；下次启动显示为暂停，可以继续。来源不支持续传时可能重新下载。合并阶段中断后可能重新合并。
- 强制杀进程或系统断电可能使临时 Cookie 文件留在 macOS 临时目录；正常退出和取消会清理。

## 支持边界

网站支持来自 [yt-dlp](https://github.com/yt-dlp/yt-dlp)。实际可用的画质受源视频、账号、会员权限、地区、站点反自动化限制和解析器版本影响。应用只列出非 DRM 格式，不解锁会员权限。

“最佳画质”选择当前最佳视频轨道与音轨。画质选项同时限定分辨率和帧率；Bilibili 还限定来源画质档位，高码率与普通高清分别列出，同一档内自动选择编码。“指定格式”可进一步限定编码。下载前显示视频与音轨合计大小，估算值标“约”，完成后显示实际文件大小。MP4 选项只转换封装、不重编码；高质量 AV1、VP9 或 HDR 文件可能需要兼容播放器。字幕选项保存现有中文和英文字幕，不自动生成字幕。

画质列表的帧率取自来源网站的格式信息，部分来源会给出近似值；它不是下载后逐帧扫描的结果。

1.1.3 将 Bilibili 的 1080p 高清与 1080p 高码率分开显示、选择和估算大小，下载不会自动替换为另一档。高码率与高帧率是两个属性；只有源站实际提供 60 fps 才会标注 60 fps。解析结果还会显示官方接口返回的登录与大会员状态，状态只用于本次解析，不保存为长期会员判断。

1.1.4 修复 Bilibili 分离音视频合并时的同步问题。视频与音轨可能从同一时间轴的不同位置开始；合并会保留它们原本的相对时间，避免分别归零导致画面提前、声音显得延迟。此修复保留原编码和帧率，不重新压缩视频，也不对所有视频添加固定的声音偏移。已经完成的旧文件需要重新下载才会采用新的合并方式。

若来源网页或接口超时，可稍后继续原任务；多连接只改善媒体传输，无法保证站点解析服务始终可访问。

1.1.2 对普通 Bilibili BV / av 视频优先读取官方视频信息接口，接口不可用时回退到网页。接口已提供的分 P 列表直接复用；可选章节查询最多等待 5 秒，字幕查询保留原超时设置。画质、登录权限、分 P 选择、签名播放请求与字幕仍使用官方 yt-dlp 逻辑。番剧回跳保留，互动视频与其他链接沿用原解析器。适配器以 ZIP 打包并只从应用内加载，不加载用户目录中的插件。这个改动减少网页超时造成的失败，不承诺源站在任何网络下始终可达。

账号登录需要本人完成。自动下载测试默认使用访客身份；显式提供 `--use-bilibili-login` 时才会使用应用已保存的 Bilibili 账号。测试目录与原队列隔离，不改变应用偏好设置。仅下载你有权保存的内容。


## 多连接加速

在这台 Mac 上，自动选路曾导致 Bilibili 解析超时，而 IPv4 对照成功；当前构建让解析器与下载器使用 IPv4，不修改系统网络设置。

默认对 HTTP / HTTPS 文件启用最多 8 个连接，HLS / DASH 分片使用原生并发下载。可在“账号与设置”关闭新任务的加速；已经使用 aria2 的任务会保留其续传方式，防止把稀疏分片误当成完整文件。

旧版连续下载的 `.part` 可以由新版接管；新版的 `.aria2` 控制文件与 `.part` 必须一起保留。已验证旧分片接管、暂停、继续后的完整文件与原始样本 SHA-256 一致。

2026-09-30，同一 Bilibili 媒体地址的三轮各 15 秒测试，单连接平均为 1.4 / 3.4 MiB/s，8 连接为 6.6 MiB/s。这个结果不代表每个视频都有相同速度：CDN、账号、站点限速与本机网络都会影响吞吐量。

## 在另一台机器构建

当前构建针对 Apple Silicon、macOS 14+。原始版本验证时使用 FFmpeg 7.1.1、Node 24 与 aria2 1.37.0，应用使用本机安装的这些组件，它们没有内置于应用包。

需要 Xcode Command Line Tools、Python 3.11+，以及位于 `/opt/homebrew/bin` 或 `/usr/local/bin` 的 FFmpeg、Node 和 aria2。源码包含固定版本的引擎下载脚本以及 SHA-256 校验。

```sh
python3 fetch-engine.py
./build.sh /absolute/path/to/output
```

当前构建使用 macOS 26.5 SDK。构建脚本在该 SDK 存在时优先使用它，可通过 `PICKVIDEO_SDK=/absolute/path/to/SDK ./build.sh` 指定其他 SDK；不会更改系统的开发工具设置。

重新制作图标：

```sh
swift make-icon.swift Resources/AppIcon.iconset
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

构建脚本运行 38 项核心检查；`--login-detection-test` 验证 13 项扫码登录回归场景，覆盖通知遗漏、延迟 Cookie、核验重试与关闭窗口后的取消；`--auth-lifecycle-test` 另外验证等待登录状态时停止、暂停、重试、临时凭据清理及测试隔离。`Tests/test_media_sync.py` 在固定版本 yt-dlp 与实际 FFmpeg 下运行 7 项合并回归：复现旧流程的时间偏移丢失，检查不同起始时间、已经同步的轨道、MKV 和后续 MP4 封装转换，并逐包验证相对时间与媒体数据保持完整。完整集成测试使用真实网络，默认不读取账号 Cookie：

```sh
/absolute/path/to/拾影.app/Contents/MacOS/PickVideo --integration-test 'https://www.youtube.com/watch?v=jNQXAC9IVRw' /absolute/path/to/test-output
```

离线 Python 回归需要固定版本的 yt-dlp：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
.venv/bin/python -B Tests/test_bilibili_api.py
.venv/bin/python -B Tests/test_media_sync.py
```

推送与应用版本一致的 `v` 标签，例如 `v1.1.4`，会触发 GitHub Actions 构建、回归检查和打包。所有检查通过后，工作流上传 DMG、ZIP 和 SHA-256 校验文件，再公开 Release。只发布本项目的应用与源码，忽略本机凭据、媒体、历史和编译缓存。

## 结构

- `Sources/Core.swift`：链接、元数据、格式选择、钥匙串、子进程与取消。
- `Sources/AppModel.swift`：解析、队列、历史、暂停重试、引擎更新。
- `Sources/Views.swift`：下载、队列、设置及内置登录界面。
- `Sources/BilibiliLogin.swift`：扫码登录检测、官方核验与重试。
- `Sources/LoginRegressionTests.swift`：不访问账号或网络的登录回归检查。
- `Resources/engine-plugins/`：Bilibili 官方元数据接口适配器。
- `Tests/test_bilibili_api.py`：固定版本 yt-dlp 下的 15 项离线适配器回归检查，覆盖接口失败、权限错误、分 P、帧率、番剧回跳、可选请求超时、域名边界和会员状态隔离。
- `Tests/test_media_sync.py`：本地生成音视频样本，使用实际合并程序验证同步、时间戳与媒体数据完整性。
- `Sources/Main.swift`：应用生命周期与检查入口。

不通过 shell 执行用户输入。引擎运行在独立进程组，取消信号同时到达下载器与 FFmpeg。文件名来自受限模板，每个任务带有独立标识，避免覆盖已有视频。

## 第三方声明

原始应用源代码见 LICENSE。yt-dlp 使用 Unlicense；官方 macOS 打包引擎包含 GPLv3+ 组件，相关条款和完整第三方声明在 `Resources/licenses/`。官方引擎源码和构建信息见 [yt-dlp 2026.08.19](https://github.com/yt-dlp/yt-dlp/tree/2026.08.19)。FFmpeg、Node 与 aria2 使用本机安装。aria2 的官方文档见 https://aria2.github.io/manual/en/html/aria2c.html。
