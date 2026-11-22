import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var page = "download"
    @Published var input = "" { didSet { if input != oldValue { invalidatePreview() } } }
    @Published var video: VideoInfo?
    @Published var analyzing = false
    @Published var analysisPhase = "正在读取画质…"
    @Published var analysisError = ""
    @Published var analysisLog = ""
    @Published var notice = ""
    @Published var selection = "best"
    @Published var selectedFormat = ""
    @Published var container = "auto"
    @Published var subtitles = false
    @Published var jobs: [DownloadJob] = []
    @Published var showLogin = false
    @Published var showHelp = false
    @Published var showLog: UUID?
    @Published var updating = false
    @Published var engineVersion = "2026.08.19"
    @Published var linkedBilibili: Bool
    @Published var bilibiliAccountName: String
    @Published var accelerated: Bool { didSet { if savesPreferences { UserDefaults.standard.set(accelerated, forKey: "accelerated") } } }
    @Published var loginChoice: String { didSet { if savesPreferences { UserDefaults.standard.set(loginChoice, forKey: "loginChoice") } } }
    @Published var cookieFile: String { didSet { if savesPreferences { UserDefaults.standard.set(cookieFile, forKey: "cookieFile") } } }
    @Published var destination: String { didSet { if savesPreferences { UserDefaults.standard.set(destination, forKey: "destination") } } }
    private var analysisRun: EngineRun?
    private var downloadRun: EngineRun?
    private var updateRun: EngineRun?
    private var activeID: UUID?
    private var analysisID = UUID()
    private var downloadStartID = UUID()
    private let credentialLoader: @Sendable (String, String) async throws -> ([String], URL?)
    private let historyURL: URL
    private let testRateLimit: Int?
    private let savesPreferences: Bool
    private var analyzedSource: AnalysisSnapshot?
    private var downloadSources: [UUID: AnalysisSnapshot] = [:]
    var busy: Bool { analyzing || activeID != nil || updating }
    var activeCount: Int { jobs.filter { $0.state.isActive || $0.state == .queued }.count }
    var completedCount: Int { jobs.filter { $0.state == .completed }.count }
    var installedBrowsers: [(String, String, String)] {
        [("chrome", "Google Chrome", "com.google.Chrome"), ("edge", "Microsoft Edge", "com.microsoft.edgemac"),
         ("firefox", "Firefox", "org.mozilla.firefox"), ("brave", "Brave", "com.brave.Browser"),
         ("safari", "Safari", "com.apple.Safari")].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.2) != nil }
    }
    init(testDirectory: URL? = nil, testRateLimit: Int? = nil,
         credentialLoader: @escaping @Sendable (String, String) async throws -> ([String], URL?) = { try await Credentials.argumentsAsync(auth: $0, file: $1) }) {
        self.credentialLoader = credentialLoader
        self.testRateLimit = testRateLimit
        self.savesPreferences = testDirectory == nil
        let defaults = UserDefaults.standard
        accelerated = defaults.object(forKey: "accelerated") == nil || defaults.bool(forKey: "accelerated")
        linkedBilibili = defaults.bool(forKey: "linkedBilibili")
        bilibiliAccountName = defaults.string(forKey: "bilibiliAccountName") ?? ""
        loginChoice = defaults.string(forKey: "loginChoice") ?? "none"
        cookieFile = defaults.string(forKey: "cookieFile") ?? ""
        destination = testDirectory?.path ?? defaults.string(forKey: "destination") ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("拾影").path
        historyURL = testDirectory?.appendingPathComponent("history.json") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PickVideo/history.json")
        if let data = try? Data(contentsOf: historyURL), let loaded = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            jobs = loaded.map { job in var j = job; if j.state.isActive || j.state == .queued { j.state = .paused; j.phase = "上次关闭时暂停，可继续下载" }; return j }
        }
        if testDirectory != nil { linkedBilibili = false; loginChoice = "none"; cookieFile = "" }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch { notice = "下载记录未能保存：\(error.localizedDescription)" }
    }
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = "剪贴板里没有文字链接。"; return }
        input = text; analysisError = ""
    }
    func invalidatePreview() {
        analysisID = UUID(); analysisRun?.cancel(); analysisRun = nil
        analyzedSource = nil
        analyzing = false; video = nil; analysisError = ""; analysisLog = ""
    }
    func auth(for url: String) -> String { LinkParser.isBilibili(url) && linkedBilibili ? "bilibili" : loginChoice }
    func analyze() {
        guard !analyzing, !updating else { return }
        analysisError = ""; analysisLog = ""; notice = ""; video = nil; analyzedSource = nil
        do {
            let urls = try LinkParser.urls(in: input)
            let url = urls[0], id = UUID(); analysisID = id
            let source = auth(for: url), file = cookieFile
            analyzing = true; analysisPhase = source == "bilibili" ? "正在读取登录状态，请留意系统确认…" : "正在读取画质…"
            if urls.count > 1 { notice = "先显示第一个视频。下方可将全部 \(urls.count) 个链接加入队列。" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let (authentication, temporaryFile) = try await self.credentialLoader(source, file)
                    guard self.analysisID == id else {
                        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                        return
                    }
                    let run = EngineRun(), collector = LineCollector(); self.analysisRun = run; self.analysisPhase = "正在读取画质…"
                    run.start(arguments: Tools.baseArguments + authentication + ["--dump-single-json", "--skip-download", "--no-quiet", "--no-warnings", "--", url], timeout: 150, onLine: { [weak self] line in
                        collector.append(line)
                        let phase: String?
                        if line.contains("Reading Bilibili video metadata API") { phase = "正在读取 B 站视频信息…" }
                        else if line.contains("Video metadata API unavailable") { phase = "正在尝试 B 站备用解析方式…" }
                        else if line.contains("Downloading wbi sign") { phase = "正在获取 B 站播放签名…" }
                        else if line.contains("Downloading video formats") { phase = "正在读取可用画质…" }
                        else if line.contains("Extracting chapters") { phase = "画质已读取，正在整理视频信息…" }
                        else { phase = nil }
                        if let phase { DispatchQueue.main.async { if let self, self.analysisID == id, self.analyzing { self.analysisPhase = phase } } }
                    }, completion: { [weak self] status, cancelled in
                        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                        let lines = collector.snapshot()
                        DispatchQueue.main.async {
                            guard let self, self.analysisID == id else { return }
                            self.analyzing = false; self.analysisRun = nil
                            self.analysisLog = lines.filter { !$0.hasPrefix("{") && $0 != "null" && !$0.isEmpty }.joined(separator: "\n")
                            if cancelled { self.analysisError = "解析已停止。如果是等待超时，请检查网络或登录后重试。"; return }
                            guard status == 0, let raw = lines.last(where: { $0.hasPrefix("{") }), let data = raw.data(using: .utf8) else {
                                self.analysisError = ErrorAdvice.explain(self.analysisLog); return
                            }
                            do {
                                self.video = try VideoInfo(data: data, originalURL: url)
                                self.analyzedSource = AnalysisSnapshot(url: url, auth: source, cookieFile: file, data: data, created: Date())
                                self.selection = "best"; self.selectedFormat = ""
                            }
                            catch { self.analysisError = error.localizedDescription }
                        }
                    })
                } catch {
                    guard self.analysisID == id else { return }
                    self.analyzing = false; self.analysisError = error.localizedDescription
                }
            }
        } catch { analysisError = error.localizedDescription }
    }
    func stopAnalysis() {
        analysisID = UUID(); analysisRun?.cancel(); analysisRun = nil; analyzing = false
        analysisError = "解析已停止。"
    }
    func currentOptions(for url: String, exact: Bool = true) -> DownloadOptions {
        var o = DownloadOptions(); o.selection = selection; o.container = container; o.subtitles = subtitles
        o.destination = destination; o.auth = auth(for: url); o.cookieFile = cookieFile
        if exact, selection == "exact", let f = video?.formats.first(where: { $0.id == selectedFormat }) {
            o.exactFormat = f.id; o.exactHasAudio = f.hasAudio; o.exactHasVideo = f.hasVideo
        }
        if selection == "exact" && o.exactFormat == nil { o.selection = "best" }
        o.accelerated = accelerated && Tools.find("aria2c") != nil
        if video?.url == url { o.preview = video?.summary(for: o) }
        return o
    }
    var currentPreview: MediaSummary? { video.flatMap { currentOptions(for: $0.url).preview } }
    func enqueue(all: Bool = false) {
        guard !updating else { return }
        do {
            let urls = all ? try LinkParser.urls(in: input) : [video?.url].compactMap { $0 }
            guard !urls.isEmpty else { throw AppError.message("请先解析一个视频链接。") }
            guard Tools.find("ffmpeg") != nil else { throw AppError.message("找不到 FFmpeg。请在「账号与设置」查看依赖状态。") }
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: destination) else { throw AppError.message("这个文件夹不可写，请更换保存位置。") }
            guard jobs.count + urls.count <= 1000 else { throw AppError.message("队列记录已满，请先清除完成的记录。") }
            var added = 0
            for url in urls {
                var options = currentOptions(for: url, exact: !all)
                if all && options.selection == "exact" { options.selection = "best" }
                let duplicate = jobs.contains { $0.url == url && $0.options.selector == options.selector && ($0.state.isActive || $0.state == .queued) }
                if duplicate { continue }
                let title = video?.url == url ? video!.title : URL(string: url)?.host ?? url
                var job = DownloadJob(url: url, title: title, options: options); job.media = options.preview
                if let snapshot = analyzedSource, snapshot.matches(url: url, auth: options.auth, cookieFile: options.cookieFile) {
                    downloadSources[job.id] = snapshot
                }
                jobs.append(job); added += 1
            }
            notice = added == 0 ? "相同视频和画质已在队列中。" : "已添加 \(added) 个下载任务。"
            persist(); page = "queue"; startNext()
        } catch { analysisError = error.localizedDescription }
    }
    private func startNext() {
        guard activeID == nil, !updating, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
        if jobs[index].options.accelerated == nil { jobs[index].options.accelerated = accelerated && Tools.find("aria2c") != nil }
        let job = jobs[index], id = job.id
        let attempt = UUID(); downloadStartID = attempt; activeID = id
        jobs[index].state = .downloading; jobs[index].phase = "正在准备下载与登录状态"; jobs[index].error = ""; jobs[index].log = ""
        persist()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if job.options.accelerated == true && Tools.find("aria2c") == nil { throw AppError.message("此任务使用多连接续传，但 aria2 组件不可用。请恢复该组件后继续，避免损坏已有分片。") }
                let (authentication, temporaryFile) = try await self.credentialLoader(job.options.auth, job.options.cookieFile)
                guard self.downloadStartID == attempt, self.activeID == id,
                      let current = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[current].state.isActive else {
                    if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                    return
                }
                let snapshot = downloadSources[id].flatMap { $0.matches(url: job.url, auth: job.options.auth, cookieFile: job.options.cookieFile) ? $0 : nil }
                let sourceFile: URL?
                do { sourceFile = try snapshot?.temporaryFile() }
                catch {
                    if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                    throw error
                }
                let run = EngineRun(); downloadRun = run
                jobs[current].phase = "正在连接视频来源"
                persist()
                let rateArguments = testRateLimit.map { ["--limit-rate", String($0)] } ?? []
                let sourceArguments = sourceFile.map { ["--load-info-json", $0.path] } ?? ["--", job.url]
                run.start(arguments: Tools.baseArguments + authentication + job.options.arguments(id: id, sourceURL: job.url) + rateArguments + sourceArguments, onLine: { [weak self] line in
                    DispatchQueue.main.async { self?.receive(line, id: id) }
                }, completion: { [weak self] code, cancelled in
                    if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                    if let sourceFile { try? FileManager.default.removeItem(at: sourceFile) }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                            if self.jobs[i].state == .paused || self.jobs[i].state == .cancelled { }
                            else if cancelled { self.jobs[i].state = .cancelled }
                            else if code == 0 && !self.jobs[i].files.isEmpty && self.jobs[i].files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                                self.jobs[i].state = .completed; self.jobs[i].progress = 1; self.jobs[i].phase = "已保存到本机"
                                let bytes = self.jobs[i].files.reduce(0.0) { total, file in total + (((try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? NSNumber)?.doubleValue ?? 0) }
                                if bytes > 0 { self.jobs[i].media?.bytes = bytes; self.jobs[i].media?.estimated = false }
                            } else { self.jobs[i].state = .failed; self.jobs[i].error = ErrorAdvice.explain(self.jobs[i].log) }
                        }
                        if let job = self.jobs.first(where: { $0.id == id }), job.state != .paused { self.downloadSources.removeValue(forKey: id) }
                        self.activeID = nil; self.downloadRun = nil; self.persist(); self.startNext()
                    }
                })
            } catch {
                guard self.downloadStartID == attempt, self.activeID == id else { return }
                if let current = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[current].state = .failed; self.jobs[current].error = error.localizedDescription }
                self.activeID = nil; self.persist(); self.startNext()
            }
        }
    }
    private func receive(_ line: String, id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state.isActive else { return }
        if let progress = AriaProgress.parse(line) {
            jobs[i].progress = progress.total > 0 ? min(progress.downloaded / progress.total, 1) : 0
            jobs[i].streamBytes = progress.downloaded; jobs[i].streamTotal = progress.total; jobs[i].connections = progress.connections
            jobs[i].speed = SizeEstimate.text(progress.speed) + "/s"
            if progress.speed > 0 {
                let eta = Int(max(0, (progress.total - progress.downloaded) / progress.speed))
                jobs[i].eta = eta < 60 ? "剩余 \(eta) 秒" : "剩余 \(eta / 60) 分钟"
            }
            jobs[i].phase = "多连接下载 · \(progress.connections) 个连接"
        } else if line.hasPrefix("__MEDIA__"), let data = line.dropFirst(9).data(using: .utf8), let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let format = MediaFormat(metadata, bilibili: LinkParser.isBilibili(jobs[i].url)) {
            let duration = (metadata["duration"] as? NSNumber)?.doubleValue ?? 0
            let actual = MediaSummary.from(format, duration: duration)
            if jobs[i].options.selection == "audio" || jobs[i].options.selection == "mp3" {
                jobs[i].media = MediaSummary(quality: jobs[i].options.selection == "mp3" ? "MP3 音频（转码）" : "原始音频 · \(format.codec)", bytes: actual.bytes, estimated: actual.estimated)
                if jobs[i].options.selection == "mp3" { jobs[i].media?.bytes = nil; jobs[i].media?.unknownReason = "转码完成后确定" }
            } else { jobs[i].media = actual }
            persist()
        } else if line.hasPrefix("__PROGRESS__"), let data = line.dropFirst(12).data(using: .utf8),
           let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let downloaded = (p["downloaded_bytes"] as? NSNumber)?.doubleValue ?? 0
            let total = (p["total_bytes"] as? NSNumber)?.doubleValue ?? (p["total_bytes_estimate"] as? NSNumber)?.doubleValue ?? 0
            jobs[i].progress = total > 0 ? min(downloaded / total, 1) : 0
            jobs[i].streamBytes = downloaded; jobs[i].streamTotal = total
            if let speed = (p["speed"] as? NSNumber)?.doubleValue { jobs[i].speed = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s" }
            if let eta = (p["eta"] as? NSNumber)?.intValue { jobs[i].eta = eta < 60 ? "剩余 \(eta) 秒" : "剩余 \(eta / 60) 分钟" }
            if let filename = p["filename"] as? String { jobs[i].phase = URL(fileURLWithPath: filename).pathExtension == "m4a" ? "正在下载音轨" : "正在下载媒体流" }
            if p["status"] as? String == "finished" { jobs[i].phase = "当前媒体流下载完成" }
        } else if line.hasPrefix("__TITLE__"), let data = line.dropFirst(9).data(using: .utf8), let title = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            jobs[i].title = title
        } else if line.hasPrefix("__FILE__"), let data = line.dropFirst(8).data(using: .utf8), let path = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            if !jobs[i].files.contains(path) { jobs[i].files.append(path) }
        } else {
            jobs[i].log += line + "\n"
            if jobs[i].log.count > 20000 { jobs[i].log = String(jobs[i].log.suffix(15000)) }
            if line.contains("[Merger]") || line.contains("[VideoRemuxer]") || line.contains("[ExtractAudio]") || line.contains("[Fixup") {
                jobs[i].state = .processing; jobs[i].phase = "正在合并与整理文件"; jobs[i].speed = ""; jobs[i].eta = ""
            }
        }
    }
    func pause(_ id: UUID, cancel: Bool = false) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = cancel ? .cancelled : .paused; jobs[i].phase = cancel ? "已停止，临时分片保留" : "保留下载进度，可继续"
        if cancel { downloadSources.removeValue(forKey: id) }
        if activeID == id {
            if let downloadRun { downloadRun.cancel() }
            else { downloadStartID = UUID(); activeID = nil }
        }
        persist(); startNext()
    }
    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].state.isActive, activeID != id else { return }
        jobs[i].options.auth = auth(for: jobs[i].url); jobs[i].options.cookieFile = cookieFile
        jobs[i].state = .queued; jobs[i].error = ""; jobs[i].speed = ""; jobs[i].eta = ""
        persist(); startNext()
    }
    func inspect(_ job: DownloadJob) { input = job.url; page = "download"; analyze() }
    func clearCompleted() { jobs.removeAll { $0.state == .completed }; persist() }
    func remove(_ id: UUID) { guard activeID != id else { return }; jobs.removeAll { $0.id == id }; downloadSources.removeValue(forKey: id); persist() }
    func reveal(_ job: DownloadJob) {
        let existing = job.files.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: job.options.destination)) }
        else { NSWorkspace.shared.activateFileViewerSelecting(existing.map { URL(fileURLWithPath: $0) }) }
    }
    func openFile(_ job: DownloadJob) { if let path = job.files.first { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "保存到这里"; panel.directoryURL = URL(fileURLWithPath: destination)
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.destination = url.path }
        }
    }
    func chooseCookies() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "使用此文件"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.hasPrefix("# Netscape HTTP Cookie File") || text.hasPrefix("# HTTP Cookie File") else { throw AppError.message("请选择 Netscape 格式的 cookies.txt 文件。") }
                self.cookieFile = url.path; self.loginChoice = "file"; self.notice = "已选择 Cookie 文件。"
            } catch { self.notice = error.localizedDescription }
        }
    }
    func loginSaved(name: String = "Bilibili 账号") { invalidatePreview(); downloadSources.removeAll(); linkedBilibili = true; bilibiliAccountName = name; UserDefaults.standard.set(name, forKey: "bilibiliAccountName"); UserDefaults.standard.set(true, forKey: "linkedBilibili"); showLogin = false; notice = "已核验登录：\(name)。登录状态已保存到钥匙串，重新解析可读取当前账号可用的画质。" }
    func logoutBilibili() { invalidatePreview(); downloadSources.removeAll(); Credentials.removeBilibili(); linkedBilibili = false; bilibiliAccountName = ""; UserDefaults.standard.removeObject(forKey: "bilibiliAccountName"); UserDefaults.standard.set(false, forKey: "linkedBilibili") }
    func openBrowserLogin() {
        let url = URL(string: "https://www.youtube.com/")!
        if let browser = installedBrowsers.first(where: { $0.0 == loginChoice }), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.2) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(url) }
    }
    func updateEngine() {
        guard !busy else { notice = "请先等待解析和下载结束，再更新引擎。"; return }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PickVideo/bin")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = root.appendingPathComponent("yt-dlp")
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: Tools.engine, to: target) }
            updating = true; let run = EngineRun(), collector = LineCollector(); updateRun = run
            run.start(arguments: ["--ignore-config", "--update-to", "nightly"], timeout: 180, onLine: { collector.append($0) }, completion: { [weak self] code, cancelled in
                DispatchQueue.main.async {
                    guard let self else { return }; self.updating = false; self.updateRun = nil
                    let log = collector.snapshot().joined(separator: "\n")
                    self.notice = code == 0 && !cancelled ? "解析引擎已更新或已是最新版本。" : "更新未完成：\(ErrorAdvice.explain(log))"
                    self.refreshVersion()
                }
            })
        } catch { notice = "更新失败：\(error.localizedDescription)" }
    }
    func refreshVersion() {
        let run = EngineRun(), collector = LineCollector()
        run.start(arguments: ["--version"], timeout: 15, onLine: { collector.append($0) }, completion: { [weak self] code, _ in
            guard code == 0, let version = collector.snapshot().first else { return }
            DispatchQueue.main.async { self?.engineVersion = version }
        })
    }
    func shutdown() { analysisID = UUID(); downloadStartID = UUID(); analysisRun?.cancel(); downloadRun?.cancel(); updateRun?.cancel(); persist() }
}
