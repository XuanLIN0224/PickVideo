import SwiftUI
import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.center()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy {
            let alert = NSAlert(); alert.messageText = "退出拾影？"; alert.informativeText = "当前下载会停止。已保存的分片会保留，下次打开后可以继续下载。"; alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "继续下载")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model.shutdown()
        return .terminateNow
    }
}

struct PickVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("拾影") {
            RootView().environmentObject(model).preferredColorScheme(.light)
                .onAppear { delegate.model = model; model.refreshVersion() }
        }.defaultSize(width: 1120, height: 790).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) { Button("新建下载") { model.page = "download" }.keyboardShortcut("n", modifiers: .command) }
                CommandGroup(replacing: .help) { Button("拾影使用说明") { model.showHelp = true } }
            }
    }
}

@main
struct Entry {
    static func main() {
        if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--engine-run" {
            _ = setpgid(0, 0)
            let args = Array(CommandLine.arguments.dropFirst(2))
            let cargs = args.map { strdup($0) } + [nil]
            cargs.withUnsafeBufferPointer { pointer in _ = execv(args[0], pointer.baseAddress!) }
            fputs("Cannot start download engine.\n", stderr); exit(127)
        }
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); return }
        if CommandLine.arguments.contains("--login-detection-test") {
            Task { @MainActor in await LoginRegressionTests.run() }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--auth-lifecycle-test") {
            Task { @MainActor in await SelfTests.authenticationLifecycle() }
            dispatchMain()
        }
        if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--analysis-test" {
            Task { @MainActor in await SelfTests.analysis(url: CommandLine.arguments[2], directory: URL(fileURLWithPath: CommandLine.arguments[3])) }
            dispatchMain()
        }
        if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--integration-test" {
            Task { @MainActor in await SelfTests.integration(url: CommandLine.arguments[2], directory: URL(fileURLWithPath: CommandLine.arguments[3]), exercisePause: CommandLine.arguments.contains("--exercise-pause")) }
            dispatchMain()
        }
        PickVideoApp.main()
    }
}

enum SelfTests {
    @MainActor
    static func analysis(url: String, directory: URL) async {
        let model = AppModel(testDirectory: directory)
        if CommandLine.arguments.contains("--use-bilibili-login") { model.linkedBilibili = true }
        let started = Date()
        model.input = url; model.analyze()
        while model.analyzing && Date().timeIntervalSince(started) < 160 { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let info = model.video else {
            print("ANALYSIS FAILED: \(model.analysisError)\n\(model.analysisLog)")
            model.shutdown(); exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--select-quality"), CommandLine.arguments.indices.contains(index + 1) {
            let choice = CommandLine.arguments[index + 1]
            guard info.qualities.contains(where: { $0.id == choice }) else { print("Requested quality is absent"); model.shutdown(); exit(1) }
            model.selection = choice
        }
        print("ANALYZED: \(info.title); \(info.formats.count) formats; \(String(format: "%.1f", Date().timeIntervalSince(started))) seconds")
        for quality in info.qualities { print("QUALITY: \(quality.title)") }
        if CommandLine.arguments.contains("--report-formats") {
            for f in info.formats { print("FORMAT: \(f.id); \(f.qualityLabel); tier=\(f.sourceQuality.map { String($0) } ?? "unknown"); bitrate=\(f.bitrate); size=\(f.size(duration: info.duration).map { SizeEstimate.text($0.bytes) } ?? "unknown"); note=\(f.note)") }
        }
        if let summary = model.currentPreview { print("SELECTED: \(summary.quality); \(summary.sizeText)") }
        if let account = info.bilibiliAccount { print("ACCOUNT: \(account.label)") }
        if CommandLine.arguments.contains("--probe-download") {
            model.enqueue()
            let deadline = Date().addingTimeInterval(150)
            while model.jobs.last?.state.isActive == true && (model.jobs.last?.streamBytes ?? 0) < 2_000_000 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let job = model.jobs.last, job.state.isActive, (job.streamBytes ?? 0) >= 2_000_000 else {
                print("DOWNLOAD PROBE FAILED: \(model.jobs.last?.error ?? "No media received")\n\(model.jobs.last?.log ?? "")")
                model.shutdown(); exit(1)
            }
            model.pause(job.id)
            let stopDeadline = Date().addingTimeInterval(10)
            while model.busy && Date() < stopDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !model.busy, model.jobs.last?.state == .paused else { model.shutdown(); exit(1) }
            print("DOWNLOAD STARTED AND PAUSED: \(job.media?.quality ?? "unknown"); \(job.streamBytes ?? 0) bytes; \(job.speed); \(job.connections ?? 0) connections")
        }
        model.shutdown(); exit(0)
    }
    @MainActor
    static func authenticationLifecycle() async {
        let preferenceKeys = ["accelerated", "loginChoice", "cookieFile", "destination"]
        let preferencesBefore = UserDefaults.standard.dictionaryRepresentation().filter { preferenceKeys.contains($0.key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pickvideo-auth-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate = CredentialTestGate()
        let model = AppModel(testDirectory: root, credentialLoader: { _, _ in try await gate.load() })
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            print("PASS: \(name)")
        }
        func waitForRequest(_ count: Int) async {
            let deadline = Date().addingTimeInterval(3)
            while await gate.count < count && Date() < deadline { await Task.yield() }
            let actual = await gate.count
            check(actual == count, "credential request \(count) reached background wait")
        }
        func release(_ index: Int) async -> URL {
            let file = root.appendingPathComponent("fake-\(index).cookies")
            try! Data("test fixture".utf8).write(to: file)
            await gate.release(index, file: file)
            let deadline = Date().addingTimeInterval(3)
            while FileManager.default.fileExists(atPath: file.path) && Date() < deadline { await Task.yield() }
            return file
        }
        model.input = "https://example.invalid/video"; model.analyze()
        await waitForRequest(1)
        model.stopAnalysis()
        check(!model.analyzing && !model.busy, "stop responds while authentication is pending")
        let analysisFile = await release(0)
        check(!FileManager.default.fileExists(atPath: analysisFile.path) && model.video == nil && model.analysisError == "解析已停止。", "late analysis credentials are discarded and removed")

        let job = DownloadJob(url: "https://example.invalid/video", title: "lifecycle test", options: DownloadOptions())
        model.jobs = [job]; model.retry(job.id)
        await waitForRequest(2)
        model.pause(job.id)
        check(!model.busy && model.jobs[0].state == .paused, "pause responds while authentication is pending")
        model.retry(job.id)
        await waitForRequest(3)
        let staleFile = await release(1)
        check(!FileManager.default.fileExists(atPath: staleFile.path) && model.jobs[0].phase == "正在准备下载与登录状态", "stale credentials cannot start a retried download")
        model.pause(job.id)
        let retryFile = await release(2)
        check(!FileManager.default.fileExists(atPath: retryFile.path) && !model.busy && model.jobs[0].state == .paused, "cancelled retry cleans up temporary credentials")
        model.shutdown()
        let preferencesAfter = UserDefaults.standard.dictionaryRepresentation().filter { preferenceKeys.contains($0.key) }
        check(NSDictionary(dictionary: preferencesBefore).isEqual(to: preferencesAfter), "isolated tests preserve application preferences")
        try? FileManager.default.removeItem(at: root)
        print("Authentication lifecycle checks passed.")
        exit(0)
    }
    @MainActor
    static func integration(url: String, directory: URL, exercisePause: Bool) async {
        let model = AppModel(testDirectory: directory, testRateLimit: exercisePause ? 80000 : nil)
        if CommandLine.arguments.contains("--use-bilibili-login") { model.linkedBilibili = true }
        model.input = url; model.analyze()
        let deadline = Date().addingTimeInterval(240)
        while model.analyzing && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let info = model.video else { print("ANALYSIS FAILED: \(model.analysisError)\n\(model.analysisLog)"); exit(1) }
        print("ANALYZED: \(info.title); \(info.formats.count) formats; heights \(info.heights)")
        model.selection = info.heights.isEmpty ? "best" : "360"
        if CommandLine.arguments.contains("--resume-existing"), let existing = model.jobs.first { model.retry(existing.id) }
        else { model.enqueue() }
        if exercisePause {
            while model.jobs.last?.state.isActive == true && ((model.jobs.last?.progress ?? 0) < 0.06 || (model.jobs.last?.options.accelerated == true && model.jobs.last?.connections == nil)) && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard let job = model.jobs.last, job.state.isActive else { print("Could not pause active download"); exit(1) }
            model.pause(job.id)
            while model.busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard model.jobs.last?.state == .paused else { print("Pause state failed"); exit(1) }
            print("PAUSED at \(Int(job.progress * 100))%; process stopped")
            model.retry(job.id)
        }
        var sawProgress = false
        while model.jobs.contains(where: { $0.state.isActive || $0.state == .queued }) && Date() < deadline {
            if model.jobs.contains(where: { $0.progress > 0 }) { sawProgress = true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let job = model.jobs.last, job.state == .completed else {
            print("DOWNLOAD FAILED: \(model.jobs.last?.error ?? model.analysisError)\n\(model.jobs.last?.log ?? "")"); model.shutdown(); exit(1)
        }
        if exercisePause && job.options.accelerated == true && job.connections == nil { print("Acceleration did not produce live connection progress"); exit(1) }
        print("COMPLETED: progressSeen=\(sawProgress), files=\(job.files), quality=\(job.media?.quality ?? "unknown"), size=\(job.media?.sizeText ?? "unknown")")
        model.shutdown(); exit(0)
    }
    static func run() {
        var count = 0
        func check(_ condition: Bool, _ name: String) { guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }; count += 1; print("PASS: \(name)") }
        let urls = try! LinkParser.urls(in: "【分享】https://www.bilibili.com/video/BV1xx411c7mu/?p=2\nhttps://youtu.be/abc?x=1&y=2\nhttps://youtu.be/abc?x=1&y=2")
        check(urls.count == 2, "share text and duplicate links")
        check((try? LinkParser.urls(in: "file:///etc/passwd")) == nil, "reject non-web input")
        check((try? LinkParser.urls(in: "https://user:pass@example.com/video")) == nil, "reject URL credentials")
        check(LinkParser.isBilibili("https://www.bilibili.com/video/a") && !LinkParser.isBilibili("https://bilibili.com.evil.test/video"), "account domain boundary")
        var options = DownloadOptions()
        check(options.selector == "bestvideo+bestaudio/best", "best video with audio fallback")
        options.selection = "1080"
        check(options.selector == "bestvideo[height<=1080]+bestaudio/best[height<=1080]", "resolution cap")
        options.exactFormat = "137"; options.exactHasAudio = false
        check(options.selector == "137+bestaudio/137", "exact video adds audio")
        options.exactHasAudio = true
        check(options.selector == "137", "muxed format avoids duplicate audio")
        options.exactFormat = nil; options.selection = "mp3"
        check(options.arguments(id: UUID()).contains("--extract-audio"), "MP3 extraction enabled")
        options.destination = "/tmp/folder with ' quote; $(echo no)"
        check(options.arguments(id: UUID()).contains(options.destination), "paths remain single argument without shell")
        let data = Data(#"{"id":"sample","title":"中文 title","duration":125,"formats":[{"format_id":"137","height":1080,"width":1920,"vcodec":"avc1","acodec":"none","ext":"mp4"},{"format_id":"140","vcodec":"none","acodec":"mp4a","ext":"m4a"},{"format_id":"drm","has_drm":true,"vcodec":"avc1","ext":"mp4"},{"format_id":"sb","vcodec":"none","acodec":"none","ext":"mhtml"}]}"#.utf8)
        let info = try! VideoInfo(data: data, originalURL: "https://example.com")
        check(info.formats.count == 2 && info.heights == [1080] && info.durationText == "2:05", "metadata excludes DRM/storyboards and preserves audio")
        check((try? VideoInfo(data: Data(#"{"_type":"playlist"}"#.utf8), originalURL: "https://example.com")) == nil, "playlist rejected explicitly")
        check((try? VideoInfo(data: Data(#"{"is_live":true}"#.utf8), originalURL: "https://example.com")) == nil, "unbounded livestream rejected")
        let job = DownloadJob(url: "https://example.com", title: "中文", options: options)
        let restored = try! JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        check(restored.id == job.id && restored.options.destination == options.destination, "queue history round trip")
        check(ErrorAdvice.explain("ERROR: HTTP Error 403").contains("网站"), "actionable network failure")
        options.exactFormat = nil; options.selection = "quality:1080:5994"
        check(options.selector.contains("[height=1080][fps>=59.93][fps<=59.95]"), "quality selection preserves 59.94 fps")
        let detailed = Data(#"{"id":"quality","title":"test","duration":100,"formats":[{"format_id":"a","vcodec":"none","acodec":"aac","ext":"m4a","filesize":1000},{"format_id":"v30","vcodec":"avc1","acodec":"none","height":1080,"fps":30,"ext":"mp4","filesize":2000},{"format_id":"v60","vcodec":"avc1","acodec":"none","height":1080,"fps":60,"ext":"mp4","filesize_approx":5000}]}"#.utf8)
        let details = try! VideoInfo(data: detailed, originalURL: "https://example.com")
        check(details.qualities.map(\.title) == ["1080p · 60 fps", "1080p · 30 fps"], "same resolution retains both frame rates")
        options.selection = "quality:1080:6000"
        let preview = details.summary(for: options)!
        check(preview.bytes == 6000 && preview.estimated && preview.quality.contains("60 fps"), "preview sums video plus audio and flags estimate")
        let aria = AriaProgress.parse("[#4f3edb 102776832B/1156542848B(8%) CN:5 DL:5301554B ETA:3m18s]")
        check(aria?.downloaded == 102776832 && aria?.connections == 5 && aria?.speed == 5301554, "aria2 byte and connection progress")
        options.accelerated = true
        if let ariaPath = Tools.find("aria2c") { check(options.arguments(id: UUID()).contains("http:\(ariaPath)"), "HTTP and HTTPS use supported yt-dlp downloader key") }
        check(LoginNavigation.isTrusted(URL(string: "https://passport.biligame.com/x/passport-login/web/crossDomain")!) && !LoginNavigation.isTrusted(URL(string: "https://passport.biligame.com.attacker.test/")!), "Bilibili cross-domain login stays inside trusted boundary")
        let oldHistory = Data(#"{"id":"550E8400-E29B-41D4-A716-446655440000","url":"https://example.com","title":"old","options":{"selection":"best","exactHasAudio":false,"exactHasVideo":true,"container":"auto","subtitles":false,"audioLanguage":"","auth":"none","cookieFile":"","destination":"/tmp"},"state":"paused","progress":0.4,"speed":"","eta":"","phase":"","error":"","log":"","files":[],"createdAt":0}"#.utf8)
        let oldJob = try! JSONDecoder().decode(DownloadJob.self, from: oldHistory)
        check(oldJob.progress == 0.4 && oldJob.options.accelerated == nil && oldJob.media == nil, "v1 history and partial downloads remain readable")
        let instant = Date()
        let snapshot = AnalysisSnapshot(url: "https://example.com/video", auth: "bilibili", cookieFile: "", data: detailed, created: instant)
        check(snapshot.matches(url: snapshot.url, auth: snapshot.auth, cookieFile: "", now: instant.addingTimeInterval(119)) && !snapshot.matches(url: snapshot.url, auth: snapshot.auth, cookieFile: "", now: instant.addingTimeInterval(120)), "analysis reuse expires before stale download URLs persist")
        check(!snapshot.matches(url: "https://example.com/other", auth: snapshot.auth, cookieFile: "", now: instant) && !snapshot.matches(url: snapshot.url, auth: "none", cookieFile: "", now: instant) && !snapshot.matches(url: snapshot.url, auth: snapshot.auth, cookieFile: "other", now: instant), "analysis reuse cannot cross videos or login sources")
        let sourceFile = try! snapshot.temporaryFile()
        let permissions = (try! FileManager.default.attributesOfItem(atPath: sourceFile.path)[.posixPermissions] as! NSNumber).intValue
        check(permissions == 0o600 && (try! Data(contentsOf: sourceFile)) == detailed, "temporary video information is private and intact")
        try! FileManager.default.removeItem(at: sourceFile)
        check(Tools.baseArguments.contains("--no-plugin-dirs") && Tools.baseArguments.contains("--plugin-dirs"), "only bundled network adapter is enabled")
        let tiersData = Data(#"{"id":"bili-tiers","extractor_key":"BiliBili","duration":100,"pickvideo_account":{"logged_in":true,"vip_status":1,"vip_type":2},"formats":[{"format_id":"audio","vcodec":"none","acodec":"aac","filesize":1000},{"format_id":"regular","height":1080,"fps":29.967,"quality":80,"format":"1080P 高清","vcodec":"av01","acodec":"none","filesize":2000,"tbr":1000},{"format_id":"high264","height":1080,"fps":29.967,"quality":112,"format":"1080P 高码率","vcodec":"avc1","acodec":"none","filesize":6000,"tbr":3000},{"format_id":"highav1","height":1080,"fps":29.967,"quality":112,"format":"1080P 高码率","vcodec":"av01","acodec":"none","filesize":4000,"tbr":2000}]}"#.utf8)
        let tiers = try! VideoInfo(data: tiersData, originalURL: "https://www.bilibili.com/video/BV1test/")
        check(tiers.qualities.map(\.id) == ["quality:1080:2997:112", "quality:1080:2997:80"], "ordinary and high bitrate tiers remain separate while codecs are grouped")
        check(tiers.qualities[0].title == "1080p 高码率 · 29.97 fps" && !tiers.qualities[0].title.contains("60"), "high bitrate does not imply an invented 60 fps")
        options.selection = "quality:1080:2997:112"
        check(tiers.summary(for: options)?.bytes == 5000 && tiers.summary(for: options)?.quality.contains("高码率") == true, "high bitrate preview uses its own video and audio sizes")
        check(options.selector.components(separatedBy: "[quality=112]").count == 3, "high bitrate selector and fallback both require the selected source tier")
        options.selection = "quality:1080:2997:80"
        check(tiers.summary(for: options)?.bytes == 3000 && options.selector.contains("[quality=80]"), "ordinary 1080p cannot silently select the high bitrate tier")
        check(tiers.formats.first?.label.contains("2.00 Mbps") == true && tiers.bilibiliAccount?.label.contains("大会员有效") == true, "format list shows bitrate and server-verified membership")
        let genericFormat = MediaFormat(["format_id": "other", "vcodec": "av01", "acodec": "none", "height": 1080, "quality": 112, "format": "1080P High"])!
        check(genericFormat.bilibiliTier == nil && genericFormat.tierCaption.isEmpty, "Bilibili tier names do not leak into other websites")
        check(!BilibiliAccountStatus(loggedIn: false, vipStatus: 1, vipType: 2).label.contains("大会员有效") && BilibiliAccountStatus(loggedIn: true, vipStatus: nil, vipType: nil).label.contains("未知"), "expired and unknown account states cannot claim active membership")
        let highFPS = MediaFormat(["format_id": "60", "vcodec": "av01", "acodec": "none", "height": 1080, "fps": 59.94, "quality": 116, "format": "1080P 60帧"], bilibili: true)!
        check(highFPS.qualityLabel.contains("59.94 fps") && highFPS.bilibiliTier == 116, "real high frame rate tier preserves its supplied frame rate")
        let mergedTier = MediaFormat(["format_id": "highav1+audio", "height": 1080, "fps": 29.967, "vcodec": "av01", "acodec": "aac", "format_note": "1080P 高码率"], bilibili: true)!
        check(mergedTier.bilibiliTier == nil && mergedTier.qualityLabel.contains("1080p 高码率 · 29.97 fps"), "merged audio metadata retains the source tier name when numeric quality is absent")
        let synchronization = options.arguments(id: UUID(), sourceURL: "https://www.bilibili.com/video/BV1bVaY6sEXM/")
        check(synchronization.contains("Merger+ffmpeg_i1:-copyts") && !synchronization.contains("-start_at_zero") && !synchronization.contains("-itsoffset"), "Bilibili merging preserves source timing without a fixed audio shift")
        check(!options.arguments(id: UUID(), sourceURL: "https://www.youtube.com/watch?v=test").contains("--postprocessor-args") && !options.arguments(id: UUID(), sourceURL: "https://bilibili.com.attacker.test/video/test").contains("--postprocessor-args"), "Bilibili timestamp handling stays inside the verified site boundary")
        print("\(count) checks passed.")
    }
}

private actor CredentialTestGate {
    private var requests: [CheckedContinuation<([String], URL?), Error>?] = []
    var count: Int { requests.count }
    func load() async throws -> ([String], URL?) {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func release(_ index: Int, file: URL) {
        let continuation = requests[index]; requests[index] = nil
        continuation?.resume(returning: ([], file))
    }
}
