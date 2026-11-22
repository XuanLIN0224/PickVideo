import SwiftUI
import WebKit
import AppKit

private let ink = Color(red: 0.09, green: 0.14, blue: 0.16)
private let accent = Color(red: 0.02, green: 0.43, blue: 0.38)
private let canvas = Color(red: 0.95, green: 0.96, blue: 0.97)

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 12)
            .foregroundStyle(.white).background(accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(ink).background(configuration.isPressed ? Color.black.opacity(0.09) : Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}
extension View {
    func panel() -> some View { self.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Color.black.opacity(0.065))) }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack {
                    Text(model.page == "download" ? "新建下载" : model.page == "queue" ? "下载队列" : "账号与设置").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Label("本机处理", systemImage: "desktopcomputer").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 32).padding(.top, 23).padding(.bottom, 15)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.page == "download" { DownloadView() }
                        else if model.page == "queue" { QueueView() }
                        else { SettingsView() }
                        if !model.notice.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle").foregroundStyle(accent)
                                Text(model.notice).font(.system(size: 13)).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button { model.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                            }.padding(14).background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.frame(maxWidth: 1040, alignment: .leading).padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 32).frame(maxWidth: .infinity)
                }
            }.background(canvas)
        }.foregroundStyle(ink).tint(accent).frame(minWidth: 960, minHeight: 680)
            .sheet(isPresented: $model.showLogin) { BilibiliLoginView().environmentObject(model) }
            .sheet(isPresented: $model.showHelp) { HelpView() }
            .sheet(item: Binding(get: { model.showLog.flatMap { id in model.jobs.first { $0.id == id } } }, set: { if $0 == nil { model.showLog = nil } })) { job in
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("下载日志").font(.title2.bold()); Spacer(); Button("关闭") { model.showLog = nil } }
                    Text(job.title).font(.headline)
                    ScrollView { Text(job.log.isEmpty ? job.error : job.log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.log, forType: .string) }
                }.padding(26).frame(width: 680, height: 450)
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).frame(width: 43, height: 43).background(accent, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) { Text("拾影").font(.system(size: 23, weight: .bold)); Text("PICKVIDEO").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.white.opacity(0.45)) }
            }.padding(.top, 31).padding(.horizontal, 25).padding(.bottom, 38)
            VStack(spacing: 7) {
                nav("download", "新建下载", "plus.square")
                nav("queue", "下载队列", "tray.and.arrow.down", count: model.activeCount)
                nav("settings", "账号与设置", "person.crop.circle")
            }.padding(.horizontal, 13)
            Spacer()
            VStack(alignment: .leading, spacing: 11) {
                Text("文件留在你的电脑").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Text("按源画质保存\n音视频自动合并").font(.system(size: 12)).foregroundStyle(.white.opacity(0.43)).lineSpacing(5)
                Button { model.showHelp = true } label: { Label("使用说明", systemImage: "questionmark.circle").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.top, 8)
            }.padding(24)
            Divider().overlay(.white.opacity(0.08)).padding(.horizontal, 24)
            Text("拾影 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1")  ·  为 macOS 制作").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).padding(24)
        }.frame(width: 210).background(ink).foregroundStyle(.white)
    }
    private func nav(_ page: String, _ title: String, _ icon: String, count: Int = 0) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 22)
                Text(title).font(.system(size: 14, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.12), in: Capsule()) }
            }.padding(.horizontal, 13).padding(.vertical, 14).contentShape(Rectangle())
                .background(model.page == page ? .white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(model.page == page ? .white : .white.opacity(0.62))
    }
}

struct DownloadView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdvanced = false
    @State private var showAnalysisLog = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("把视频，留在本机。").font(.system(size: 29, weight: .bold))
            Text("粘贴链接，选择画质，然后下载。").font(.system(size: 14)).foregroundStyle(.secondary)
        }.padding(.bottom, 4)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("视频链接", systemImage: "link").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 6) { badge("Bilibili", color: .pink); badge("YouTube", color: .red); badge("更多网站", color: .secondary) }
            }
            ZStack(alignment: .topLeading) {
                if model.input.isEmpty { Text("粘贴视频链接或分享文字；多个链接请分行填写").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 13).padding(.leading, 11).allowsHitTesting(false) }
                TextEditor(text: $model.input).font(.system(size: 14)).scrollContentBackground(.hidden).padding(7).frame(height: 90).accessibilityLabel("视频链接输入框")
            }.background(canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.06)))
            HStack(spacing: 10) {
                Button { model.paste() } label: { Label("粘贴", systemImage: "doc.on.clipboard") }.buttonStyle(QuietButton())
                if !model.input.isEmpty { Button("清空") { model.input = ""; model.video = nil; model.analysisError = "" }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).disabled(model.analyzing) }
                Spacer()
                if model.analyzing {
                    ProgressView().controlSize(.small)
                    Text(model.analysisPhase).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("停止") { model.stopAnalysis() }.buttonStyle(QuietButton())
                } else {
                    Button { model.analyze() } label: { Label("解析链接", systemImage: "sparkle.magnifyingglass") }.buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: .command).disabled(model.input.isEmpty || model.updating)
                }
            }
        }.panel()
        if !model.analysisError.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(model.analysisError, systemImage: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(Color(red: 0.62, green: 0.28, blue: 0.08)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Button("账号与登录") { model.page = "settings" }
                    if !model.analysisLog.isEmpty { Button(showAnalysisLog ? "收起详情" : "查看详情") { showAnalysisLog.toggle() } }
                }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                if showAnalysisLog { Text(model.analysisLog).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        if let video = model.video { videoPanel(video) }
        else if !model.analyzing && model.analysisError.isEmpty {
            VStack(spacing: 15) {
                Image(systemName: "rectangle.stack.badge.play").font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.8)).padding(.bottom, 2)
                Text("准备好你的第一个链接").font(.system(size: 17, weight: .semibold))
                Text("读取网站实际提供的画质，保留原始清晰度。\n需要登录的视频，可先在「账号与设置」连接账号。").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                Button("连接账号") { model.page = "settings" }.buttonStyle(QuietButton()).padding(.top, 2)
            }.frame(maxWidth: .infinity).padding(.vertical, 28)
        }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder").foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 5) { Text("保存位置").font(.system(size: 12, weight: .medium)); Text(model.destination).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            Spacer()
            Button("更改") { model.chooseFolder() }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(accent)
        }.padding(.horizontal, 3)
    }
    private func badge(_ text: String, color: Color) -> some View { Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.075), in: Capsule()) }
    private func videoPanel(_ video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 17) {
                AsyncImage(url: video.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { ZStack { canvas; Image(systemName: "play.rectangle").foregroundStyle(.secondary) } }
                    .frame(width: 160, height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 10) {
                    Text(video.title).font(.system(size: 17, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                    Text([video.site, video.author, video.duration > 0 ? video.durationText : ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("已读取 \(video.formats.count) 种音视频格式").font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    if let account = video.bilibiliAccount {
                        Text(account.label).font(.system(size: 12, weight: .medium)).foregroundStyle(account.loggedIn ? accent : Color.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("下载画质").font(.system(size: 12, weight: .semibold))
                    Picker("下载画质", selection: $model.selection) {
                        Text("最佳画质 · " + (video.summary(for: DownloadOptions())?.quality ?? "自动选择")).tag("best")
                        ForEach(video.qualities) { quality in Text(quality.title).tag(quality.id) }
                        Text("仅音频 · 保留原格式").tag("audio")
                        Text("仅音频 · 转为 MP3").tag("mp3")
                        Text("指定格式 · 完整列表").tag("exact")
                    }.labelsHidden().controlSize(.large)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 9) {
                    Text("文件容器").font(.system(size: 12, weight: .semibold))
                    Picker("文件容器", selection: $model.container) { Text("自动 · 保留原编码").tag("auto"); Text("MKV · 广泛兼容编码").tag("mkv"); Text("MP4 · 封装转换").tag("mp4") }.labelsHidden().controlSize(.large).disabled(model.selection == "audio" || model.selection == "mp3")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.selection == "exact" {
                VStack(alignment: .leading, spacing: 9) {
                    Text("清单中的大小为该轨道大小；下方显示加上音轨后的预计总大小。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("具体格式", selection: $model.selectedFormat) {
                        Text("请选择格式").tag("")
                        ForEach(video.formats) { f in Text("\(f.id)  ·  \(f.label)").tag(f.id) }
                    }.labelsHidden().controlSize(.large)
                    Button(showAdvanced ? "收起格式清单" : "展开所有格式") { showAdvanced.toggle() }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 12, weight: .medium))
                    if showAdvanced {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(video.formats) { f in
                                    Button { model.selectedFormat = f.id } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: model.selectedFormat == f.id ? "checkmark.circle.fill" : "circle").foregroundStyle(accent)
                                            VStack(alignment: .leading, spacing: 5) { Text(f.label).font(.system(size: 12, weight: .medium)); Text("ID \(f.id)\(f.note.isEmpty ? "" : " · " + f.note)").font(.system(size: 10)).foregroundStyle(.secondary) }
                                            Spacer()
                                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedFormat == f.id ? accent.opacity(0.05) : .clear)
                                    }.buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }.frame(maxHeight: 260).background(canvas, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            if let preview = model.currentPreview {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("将下载的画质").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(preview.quality).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 7) {
                        Text(model.selection == "audio" || model.selection == "mp3" ? "预计音频大小" : "预计总大小 · 含音轨").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(preview.sizeText).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(accent)
                    }
                }.padding(16).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            }
            HStack {
                Toggle("同时保存中文 / 英文字幕（如有）", isOn: $model.subtitles).font(.system(size: 12)).toggleStyle(.checkbox)
                Spacer()
            }
            if model.container == "mp4" { Text("MP4 只转换封装，不改变原编码。某些 AV1、VP9 或 HDR 文件在 QuickTime 中可能无法播放；可选 MKV 并用兼容播放器打开。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(model.auth(for: video.url) == "none" ? "当前使用访客身份" : "已启用登录状态").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if let urls = try? LinkParser.urls(in: model.input), urls.count > 1 { Button("下载全部 \(urls.count) 个链接") { model.enqueue(all: true) }.buttonStyle(QuietButton()) }
                Button { model.enqueue() } label: { Label("加入下载队列", systemImage: "arrow.down.to.line") }.buttonStyle(PrimaryButton()).disabled(model.selection == "exact" && model.selectedFormat.isEmpty)
            }
            Text("画质由原视频和账号权限决定。仅下载你有权保存的内容。").font(.system(size: 11)).foregroundStyle(.secondary)
        }.panel()
    }
}

struct QueueView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) { Text("你的下载").font(.system(size: 29, weight: .bold)); Text("\(model.activeCount) 个进行中  ·  \(model.completedCount) 个已完成").font(.system(size: 14)).foregroundStyle(.secondary) }
            Spacer()
            if model.completedCount > 0 { Button("清除已完成记录") { model.clearCompleted() }.buttonStyle(QuietButton()).help("只清除记录，保留视频文件") }
        }
        if model.jobs.isEmpty {
            VStack(spacing: 17) {
                Image(systemName: "tray").font(.system(size: 36, weight: .light)).foregroundStyle(accent)
                Text("队列还是空的").font(.system(size: 18, weight: .semibold))
                Text("添加一个视频链接，就能在这里查看下载进度。").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("添加视频") { model.page = "download" }.buttonStyle(PrimaryButton())
            }.frame(maxWidth: .infinity).padding(.vertical, 80).panel()
        } else {
            LazyVStack(spacing: 13) { ForEach(model.jobs.reversed()) { job in jobCard(job) } }
        }
    }
    private func jobCard(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: job.state == .completed ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.circle" : "film")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(job.state == .failed ? .orange : accent).frame(width: 38, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(job.media?.quality ?? job.options.label).font(.system(size: 13, weight: .medium)).foregroundStyle(accent)
                    Text([URL(string: job.url)?.host ?? "", (job.state == .completed ? "文件大小 " : "预计总大小 ") + (job.media?.sizeText ?? job.options.preview?.sizeText ?? "解析后显示")].joined(separator: "  ·  ")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(job.state.title).font(.system(size: 11, weight: .medium)).foregroundStyle(job.state == .failed ? .orange : accent).padding(.horizontal, 9).padding(.vertical, 5).background(accent.opacity(0.07), in: Capsule())
            }
            if job.state.isActive {
                if job.state == .processing { ProgressView().progressViewStyle(.linear) }
                else { ProgressView(value: job.progress).progressViewStyle(.linear) }
                HStack {
                    Text(job.phase).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text([job.state == .downloading ? "当前流 \(Int(job.progress * 100))%" : "", job.speed, job.eta].filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                if let done = job.streamBytes, let total = job.streamTotal, total > 0 {
                    Text("当前媒体流：\(SizeEstimate.text(done)) / \(SizeEstimate.text(total))").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if !job.error.isEmpty { Text(job.error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack(spacing: 10) {
                if job.state == .completed {
                    Button { model.openFile(job) } label: { Label("打开视频", systemImage: "play") }.buttonStyle(QuietButton())
                    Button { model.reveal(job) } label: { Label("在 Finder 显示", systemImage: "folder") }.buttonStyle(QuietButton())
                } else if job.state.isActive || job.state == .queued {
                    Button("暂停") { model.pause(job.id) }.buttonStyle(QuietButton())
                    Button("取消") { model.pause(job.id, cancel: true) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button(job.state == .paused ? "继续下载" : "重试") { model.retry(job.id) }.buttonStyle(QuietButton())
                    Button("移除记录") { model.remove(job.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("查看画质与大小") { model.inspect(job) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
                }
                Spacer()
                Button("日志") { model.showLog = job.id }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.panel()
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { Text("连接你的账号").font(.system(size: 29, weight: .bold)); Text("让下载器读取你已经有权观看的视频和画质。").font(.system(size: 14)).foregroundStyle(.secondary) }
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "play.tv").font(.system(size: 24)).foregroundStyle(.pink).frame(width: 44)
                VStack(alignment: .leading, spacing: 5) { Text("Bilibili").font(.system(size: 17, weight: .semibold)); Text(model.linkedBilibili ? (model.bilibiliAccountName.isEmpty ? "已保存登录状态 · 解析时复核" : "已连接：\(model.bilibiliAccountName)") : "在应用内扫码；登录后自动识别账号").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button(model.linkedBilibili ? "重新登录" : "登录 Bilibili") { model.showLogin = true }.buttonStyle(PrimaryButton())
            }
            Text("登录状态存放在 macOS 钥匙串。Bilibili 链接会优先使用这个账号；可访问的高画质随账号会员权限变化。").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.linkedBilibili { Button("退出并清除登录状态") { model.logoutBilibili() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.panel()
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 13) {
                Image(systemName: "globe").font(.system(size: 24)).foregroundStyle(accent).frame(width: 44)
                VStack(alignment: .leading, spacing: 5) { Text("YouTube 与其他网站").font(.system(size: 17, weight: .semibold)); Text("使用本机浏览器中已有的登录状态").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Picker("登录来源", selection: $model.loginChoice) {
                Text("不使用登录状态（访客）").tag("none")
                ForEach(model.installedBrowsers, id: \.0) { b in Text(b.1).tag(b.0) }
                Text("导入的 Cookie 文件").tag("file")
            }.controlSize(.large)
            Text("先在所选浏览器打开网站并登录，再回到这里解析链接。选择浏览器后，解析与下载时会在本机读取其 Cookie；macOS 可能要求钥匙串或文件访问权限。").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.loginChoice == "safari" { Text("Safari 的 Cookie 可能需要完全磁盘访问权限。遇到读取失败时，可选择 Chrome / Firefox，或导入 Cookie 文件。").font(.system(size: 12)).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                Button { model.openBrowserLogin() } label: { Label("打开 YouTube 登录", systemImage: "safari") }.buttonStyle(QuietButton())
                Button("导入 cookies.txt") { model.chooseCookies() }.buttonStyle(QuietButton())
            }
            if model.loginChoice == "file" { Text(model.cookieFile.isEmpty ? "尚未选择文件。请选择 Netscape 格式的 cookies.txt。" : "已选择：\(URL(fileURLWithPath: model.cookieFile).lastPathComponent)").font(.system(size: 12)).foregroundStyle(.secondary) }
            Text("不会要求你在下载器中输入 Google 密码。登录信息仅在本机处理，并用于访问对应网站。").font(.system(size: 12)).foregroundStyle(.secondary)
        }.panel()
        VStack(alignment: .leading, spacing: 15) {
            Text("下载与维护").font(.system(size: 17, weight: .semibold))
            HStack { VStack(alignment: .leading, spacing: 5) { Text("保存文件夹").font(.system(size: 13, weight: .medium)); Text(model.destination).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }; Spacer(); Button("选择文件夹") { model.chooseFolder() }.buttonStyle(QuietButton()) }
            Divider()
            Toggle("多连接加速（最多 8 个连接）", isOn: $model.accelerated).font(.system(size: 14, weight: .medium)).toggleStyle(.checkbox)
            Text("对支持分段请求的 Bilibili 和 HTTP 视频直链启用并行下载。网站限速或网络拥堵仍会影响速度；已使用多连接的任务继续保留该模式，以安全续传。").font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("解析引擎  \(model.engineVersion)").font(.system(size: 13, weight: .medium)); Text("网站规则变化时，可更新到官方 nightly 版本。").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if model.updating { ProgressView().controlSize(.small) }
                Button(model.updating ? "正在更新…" : "更新解析引擎") { model.updateEngine() }.buttonStyle(QuietButton()).disabled(model.busy)
            }
            HStack(spacing: 20) { dependency("音视频合并", ok: Tools.find("ffmpeg") != nil); dependency("YouTube JS 运行时", ok: Tools.find("node") != nil); dependency("多连接下载", ok: Tools.find("aria2c") != nil) }
        }.panel()
    }
    private func dependency(_ name: String, ok: Bool) -> some View { Label("\(name) · \(ok ? "就绪" : "缺失")", systemImage: ok ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(ok ? accent : .orange) }
}

struct LoginWebView: NSViewRepresentable {
    let session: LoginSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> WKWebView { session.web.navigationDelegate = context.coordinator; session.web.uiDelegate = context.coordinator; return session.web }
    func updateNSView(_ view: WKWebView, context: Context) { }
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let session: LoginSession
        init(session: LoginSession) { self.session = session }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            guard ["https", "http", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame != false && url.scheme != "about" && !LoginNavigation.isTrusted(url) {
                // Authentication tickets must never be handed to another browser.
                session.error = "登录页面尝试跳转到未识别的站点，已留在应用内。可返回重试或选择浏览器登录。"
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { if action.targetFrame == nil { webView.load(action.request) }; return nil }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { session.scheduleDetection() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { session.scheduleDetection() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { session.navigationFailed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { session.navigationFailed(error) }
    }
}
struct BilibiliLoginView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var session = LoginSession()
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("登录 Bilibili").font(.system(size: 20, weight: .bold)); Text(session.status).font(.system(size: 12)).foregroundStyle(session.saving ? accent : .secondary) }; Spacer(); Button("关闭") { model.showLogin = false }.buttonStyle(QuietButton()) }.padding(22)
            Divider()
            LoginWebView(session: session)
            Divider()
            HStack { if !session.error.isEmpty { Text(session.error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }; Spacer(); if session.saving { ProgressView().controlSize(.small) }; Button("重新加载") { session.web.reload() }.buttonStyle(QuietButton()); Button("重新检测") { session.checkLogin(manual: true) }.buttonStyle(PrimaryButton()).disabled(session.saving) }.padding(20)
        }.frame(width: 860, height: 650).background(.white)
            .onAppear { session.onAuthenticated = { name in model.loginSaved(name: name) }; session.startDetection() }
            .onDisappear { session.stop() }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { Text("使用拾影").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
            help("1", "连接账号（需要时）", "Bilibili 可在应用内登录；YouTube 可使用 Chrome、Edge、Firefox 等浏览器的登录状态。登录后重新解析视频。")
            help("2", "粘贴链接，读取画质", "支持单个视频及多链接批量添加。选择「指定格式」可查看每一种源格式，包括帧率、编码、HDR 和音轨。正在直播的视频和整个播放列表暂不处理。")
            help("3", "加入队列", "文件直接保存到选定的本机文件夹。需要时自动合并音视频。默认保留原编码；MP4 封装并不保证所有播放器都能播放。")
            help("4", "暂停与继续", "暂停后保留临时分片，支持的来源会续传。合并阶段暂停后重试可能重新合并。退出应用会停止当前任务，下次打开后可继续。")
            Text("站点可能限制地区、会员、登录状态或请求频率。拾影仅列出当前能访问的非 DRM 格式，不能保证任何网站和画质都可用。仅保存你有权下载的内容。").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            Link("查看 yt-dlp 支持的网站", destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!).font(.system(size: 13))
        }.padding(30).frame(width: 610).foregroundStyle(ink)
    }
    private func help(_ number: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) { Text(number).font(.system(size: 13, weight: .bold)).frame(width: 28, height: 28).background(accent.opacity(0.1), in: Circle()).foregroundStyle(accent); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 14, weight: .semibold)); Text(body).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4) } }
    }
}
