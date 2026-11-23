# 安装拾影

## 系统要求

- Apple Silicon Mac，例如 M1、M2、M3 或后续芯片。
- macOS 14 或更新版本。
- 本机安装 FFmpeg、Node 和 aria2。当前发布包不包含这三个依赖。

## 安装

1. 在 [Releases](https://github.com/XuanLIN0224/PickVideo-Releases/releases/latest) 下载 `PickVideo-v1.1.4-macos-arm64.dmg`。`Source code` 是开发者源码，不是应用安装包。
2. 打开 DMG，将“拾影”拖到 Applications。也可以下载 ZIP，解压后将“拾影.app”移到“应用程序”。
3. 如果已经安装 [Homebrew](https://brew.sh/)，在终端运行下面的命令。没有 Homebrew 时，请先按照其官方网站的安装说明操作。

```sh
brew install ffmpeg node aria2
```

4. 打开拾影，进入“账号与设置”，确认音视频合并、YouTube JS 运行时和多连接下载都显示“就绪”。
5. 粘贴视频链接，解析并选择画质，然后加入下载队列。默认文件夹为 `~/Downloads/拾影`。

## 首次打开

这个版本采用本地 ad-hoc 签名，没有 Apple Developer ID 签名和 Apple 公证，macOS 可能阻止首次打开。请先确认下载地址属于本仓库，并参考 [Apple 关于打开未公证应用的官方说明](https://support.apple.com/en-us/102445) 决定是否信任此版本。无需关闭系统安全保护，也不需要运行移除隔离属性的命令。

`SHA256SUMS.txt` 用于检查下载内容是否与发布文件一致。将它与安装包放在同一文件夹，进入该文件夹后运行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

如果只下载了 DMG 或 ZIP，另一项会报告文件不存在。检查自己下载的文件对应的行是否为 `OK`。

## 登录和画质

Bilibili 可在应用内使用官方网页扫码登录，登录状态保存到本机钥匙串。YouTube 和其他网站可选择本人已登录的浏览器，或导入 Netscape 格式的 Cookie 文件。账号、Cookie 和下载历史不会随安装包分享给其他人。

可用画质取决于源视频和账号权限。“高码率”和“60 帧”是不同属性，应用分别显示来源档位、帧率、编码与预计大小。

1.1.4 修复了 Bilibili 分离音视频合并时丢失相对起始时间的问题。新下载会使用修复后的合并方式，已完成的旧成片不会自动改写。

## 更新与卸载

退出应用后，用新版替换“应用程序”里的旧版即可。下载历史和钥匙串登录状态位于应用包外，替换应用不会把它们打包或上传。macOS 可能再次确认钥匙串访问。

删除应用不会删除已经下载的视频。应用暂不支持 Intel Mac、Windows 或 Linux。
