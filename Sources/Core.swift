import Foundation
import AppKit
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum Tools {
    static let executable = Bundle.main.executableURL!
    static var engine: URL {
        let updated = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PickVideo/bin/yt-dlp")
        return FileManager.default.isExecutableFile(atPath: updated.path) ? updated : Bundle.main.resourceURL!.appendingPathComponent("yt-dlp")
    }
    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var baseArguments: [String] {
        // IPv4 avoids the failing automatic route observed on this Mac.
        var a = ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-color", "--force-ipv4",
                 "--socket-timeout", "20", "--retries", "3", "--fragment-retries", "3"]
        // Load only the adapter shipped inside this signed app, never user plugins.
        let plugins = Bundle.main.resourceURL!.appendingPathComponent("engine-plugins")
        if FileManager.default.fileExists(atPath: plugins.path) { a += ["--plugin-dirs", plugins.path] }
        if let ffmpeg = find("ffmpeg") { a += ["--ffmpeg-location", ffmpeg] }
        if let node = find("node") { a += ["--js-runtimes", "node:\(node)"] }
        return a
    }
}

enum LinkParser {
    static func urls(in input: String) throws -> [String] {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var seen = Set<String>()
        let urls = detector.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { match -> String? in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            let value = url.absoluteString
            return seen.insert(value).inserted ? value : nil
        }
        guard !urls.isEmpty else { throw AppError.message("请粘贴完整的 http 或 https 视频链接，也可以粘贴网站的分享文字。") }
        guard urls.count <= 50 else { throw AppError.message("每次最多添加 50 个链接。") }
        return urls
    }
    static func isBilibili(_ text: String) -> Bool {
        guard let host = URL(string: text)?.host?.lowercased() else { return false }
        return host == "b23.tv" || host == "bilibili.com" || host.hasSuffix(".bilibili.com")
    }
}

struct MediaFormat: Identifiable, Equatable {
    var id: String
    var height: Int
    var width: Int
    var fps: Double
    var ext: String
    var vcodec: String
    var acodec: String
    var note: String
    var dynamicRange: String
    var bytes: Double?
    var sizeEstimated: Bool
    var bitrate: Double
    var sourceQuality: Double?
    var bilibiliTier: Int?
    var tierCaption: String
    var language: String
    var hasVideo: Bool { vcodec != "none" }
    var hasAudio: Bool { acodec != "none" }
    var resolution: String { hasVideo ? (height >= 4320 ? "8K · \(height)p" : height >= 2160 ? "4K · \(height)p" : height > 0 ? "\(height)p" : "原始画质") : "音频" }
    var fpsText: String { fps > 0 ? (abs(fps - fps.rounded()) < 0.005 ? "\(Int(fps.rounded())) fps" : String(format: "%.2f fps", fps)) : "帧率未知" }
    var resolutionWithTier: String { resolution + (tierCaption.isEmpty ? "" : " " + tierCaption) }
    var bitrateText: String { bitrate > 0 ? (bitrate >= 1000 ? String(format: "%.2f Mbps", bitrate / 1000) : String(format: "%.0f kbps", bitrate)) : "码率未知" }
    var qualityLabel: String {
        [resolutionWithTier, hasVideo ? fpsText : "", codec, dynamicRange.isEmpty || dynamicRange == "SDR" ? "" : dynamicRange].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var codec: String {
        if !hasVideo { return acodec.components(separatedBy: ".").first?.uppercased() ?? acodec }
        if vcodec.hasPrefix("avc") { return "H.264" }
        if vcodec.hasPrefix("hev") || vcodec.hasPrefix("hvc") { return "HEVC" }
        if vcodec.hasPrefix("av01") { return "AV1" }
        if vcodec.hasPrefix("vp09") { return "VP9" }
        return vcodec.components(separatedBy: ".").first?.uppercased() ?? vcodec
    }
    var label: String {
        var parts = [resolutionWithTier, ext.uppercased(), codec]
        if hasVideo { parts += [fpsText, bitrateText] }
        if !dynamicRange.isEmpty && dynamicRange != "SDR" { parts.append(dynamicRange) }
        if !language.isEmpty { parts.append(language) }
        parts.append(hasAudio ? "含音频" : "自动配音轨")
        if let bytes { parts.append((sizeEstimated ? "约 " : "") + SizeEstimate.text(bytes)) }
        return parts.joined(separator: " · ")
    }
    init?(_ d: [String: Any], bilibili: Bool = false) {
        guard let id = d["format_id"] as? String, d["has_drm"] as? Bool != true else { return nil }
        let vc = d["vcodec"] as? String ?? "unknown", ac = d["acodec"] as? String ?? "unknown"
        guard vc != "none" || ac != "none", d["ext"] as? String != "mhtml" else { return nil }
        self.id = id; height = (d["height"] as? NSNumber)?.intValue ?? 0; width = (d["width"] as? NSNumber)?.intValue ?? 0
        fps = (d["fps"] as? NSNumber)?.doubleValue ?? 0; ext = d["ext"] as? String ?? "?"
        vcodec = vc; acodec = ac; note = d["format_note"] as? String ?? d["format"] as? String ?? ""
        dynamicRange = d["dynamic_range"] as? String ?? ""; language = d["language"] as? String ?? ""
        bytes = (d["filesize"] as? NSNumber)?.doubleValue ?? (d["filesize_approx"] as? NSNumber)?.doubleValue
        sizeEstimated = d["filesize"] as? NSNumber == nil
        bitrate = (d["tbr"] as? NSNumber)?.doubleValue ?? 0
        sourceQuality = (d["quality"] as? NSNumber)?.doubleValue
        bilibiliTier = nil; tierCaption = ""
        if bilibili, vc != "none", let quality = sourceQuality, quality.isFinite, quality >= 0, quality <= 10000, quality.rounded() == quality {
            bilibiliTier = Int(quality)
        }
        if bilibili, vc != "none" { tierCaption = BilibiliQuality.caption(tier: bilibiliTier, sourceName: note) }
    }
    func size(duration: Double) -> SizeEstimate? {
        if let bytes, bytes.isFinite, bytes > 0 { return SizeEstimate(bytes: bytes, estimated: sizeEstimated) }
        if bitrate > 0, duration > 0 { return SizeEstimate(bytes: bitrate * 1000 * duration / 8, estimated: true) }
        return nil
    }
}

enum BilibiliQuality {
    static func caption(tier: Int?, sourceName: String = "") -> String {
        let name = sourceName.components(separatedBy: "+").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.range(of: "^(?:[0-9]+[pP]|[48][kK])(?:\\s|[^A-Za-z0-9])", options: .regularExpression) != nil {
            return name.replacingOccurrences(of: "^(?:[0-9]+[pP]|[48][kK])\\s*", with: "", options: .regularExpression)
        }
        // Used when the engine's merged-stream metadata omits the source name.
        let captions = [16: "流畅", 32: "标清", 64: "准高清", 74: "高帧率", 80: "高清", 112: "高码率", 116: "高帧率", 125: "HDR", 126: "杜比视界"]
        return tier.flatMap { captions[$0] } ?? ""
    }
}

struct SizeEstimate: Equatable {
    var bytes: Double
    var estimated: Bool
    static func text(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(max(bytes.isFinite ? bytes : 0, 0), Double(Int64.max / 2))), countStyle: .file) }
}
struct MediaSummary: Codable, Equatable {
    var quality: String
    var bytes: Double?
    var estimated: Bool
    var unknownReason: String?
    var sizeText: String { bytes.map { (estimated ? "约 " : "") + SizeEstimate.text($0) } ?? unknownReason ?? "大小未知（源站未提供）" }
    static func from(_ format: MediaFormat, audio: MediaFormat? = nil, duration: Double) -> MediaSummary {
        let videoSize = format.size(duration: duration), audioSize = audio?.size(duration: duration)
        let known = videoSize != nil && (audio == nil || audioSize != nil)
        return MediaSummary(quality: format.qualityLabel, bytes: known ? (videoSize!.bytes + (audioSize?.bytes ?? 0)) : nil,
                            estimated: videoSize?.estimated == true || audioSize?.estimated == true)
    }
}
struct QualityChoice: Identifiable {
    var height: Int
    var frameRate: Int
    var tier: Int? = nil
    var tierCaption: String = ""
    var id: String { "quality:\(height):\(frameRate)" + (tier.map { ":\($0)" } ?? "") }
    var title: String {
        let resolution = height >= 4320 ? "8K · \(height)p" : height >= 2160 ? "4K · \(height)p" : "\(height)p"
        let fps = frameRate == 0 ? "帧率未知" : frameRate % 100 == 0 ? "\(frameRate / 100) fps" : String(format: "%.2f fps", Double(frameRate) / 100)
        return resolution + (tierCaption.isEmpty ? "" : " " + tierCaption) + " · " + fps
    }
}

struct BilibiliAccountStatus {
    let loggedIn: Bool
    let vipStatus: Int?
    let vipType: Int?
    var label: String {
        if !loggedIn { return "Bilibili 登录状态已失效，请重新连接账号" }
        if vipStatus == 1 { return "Bilibili 已登录 · 大会员有效" }
        return vipStatus == nil ? "Bilibili 已登录 · 会员状态未知" : "Bilibili 已登录 · 当前账号无有效大会员"
    }
}

struct VideoInfo: Identifiable {
    var id: String
    var url: String
    var title: String
    var author: String
    var site: String
    var duration: Double
    var thumbnail: URL?
    var formats: [MediaFormat]
    var subtitleLanguages: [String]
    var bilibiliAccount: BilibiliAccountStatus?
    var durationText: String {
        let seconds = Int(duration)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var heights: [Int] { Array(Set(formats.filter(\.hasVideo).map(\.height).filter { $0 > 0 })).sorted(by: >) }
    var qualities: [QualityChoice] {
        var seen = Set<String>()
        return formats.filter { $0.hasVideo && $0.height > 0 }.map { QualityChoice(height: $0.height, frameRate: Int(($0.fps * 100).rounded()), tier: $0.bilibiliTier, tierCaption: $0.tierCaption) }
            .filter { seen.insert($0.id).inserted }.sorted {
                if $0.height != $1.height { return $0.height > $1.height }
                if $0.frameRate != $1.frameRate { return $0.frameRate > $1.frameRate }
                return ($0.tier ?? -1) > ($1.tier ?? -1)
            }
    }
    func summary(for options: DownloadOptions) -> MediaSummary? {
        let audio = formats.first { !$0.hasVideo && $0.hasAudio }
        if options.selection == "audio" || options.selection == "mp3" {
            guard let f = audio ?? formats.first(where: \.hasAudio) else { return nil }
            var s = MediaSummary.from(f, duration: duration)
            s.quality = options.selection == "mp3" ? "MP3 音频（转码）" : "原始音频 · \(f.codec)"
            if options.selection == "mp3" { s.bytes = nil; s.estimated = true; s.unknownReason = "转码完成后确定" }
            return s
        }
        var selected: MediaFormat?
        if let id = options.exactFormat { selected = formats.first { $0.id == id } }
        else {
            let parts = options.selection.split(separator: ":")
            let candidates = formats.filter { f in
                guard f.hasVideo else { return false }
                if [3, 4].contains(parts.count), parts[0] == "quality", let h = Int(parts[1]), let rate = Int(parts[2]) {
                    return f.height == h && Int((f.fps * 100).rounded()) == rate && (parts.count == 3 || f.bilibiliTier == Int(parts[3]))
                }
                if let h = Int(options.selection) { return f.height > 0 && f.height <= h }
                return true
            }
            selected = candidates.first { !$0.hasAudio } ?? candidates.first
        }
        guard let selected else { return nil }
        return MediaSummary.from(selected, audio: selected.hasVideo && !selected.hasAudio ? audio : nil, duration: duration)
    }
    init(data: Data, originalURL: String) throws {
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.message("网站没有返回可读取的视频信息。") }
        guard d["_type"] as? String != "playlist" else { throw AppError.message("这是合集链接。请打开其中一个视频，粘贴它的链接；批量下载可一次粘贴多个视频链接。") }
        guard d["is_live"] as? Bool != true else { throw AppError.message("这个视频正在直播。请在直播结束后下载回放。") }
        id = d["id"] as? String ?? UUID().uuidString
        url = originalURL
        title = d["title"] as? String ?? "未命名视频"
        author = d["uploader"] as? String ?? d["channel"] as? String ?? ""
        site = d["extractor_key"] as? String ?? d["extractor"] as? String ?? "视频"
        duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
        thumbnail = (d["thumbnail"] as? String).flatMap(URL.init(string:))
        let sourceFormats = d["formats"] as? [[String: Any]] ?? [d]
        let bilibili = LinkParser.isBilibili(originalURL) || site.lowercased().hasPrefix("bilibili")
        formats = sourceFormats.compactMap { MediaFormat($0, bilibili: bilibili) }.reversed()
        subtitleLanguages = (d["subtitles"] as? [String: Any] ?? [:]).keys.filter { $0 != "live_chat" && $0 != "danmaku" }.sorted()
        if let account = d["pickvideo_account"] as? [String: Any], let loggedIn = account["logged_in"] as? Bool {
            bilibiliAccount = BilibiliAccountStatus(loggedIn: loggedIn, vipStatus: (account["vip_status"] as? NSNumber)?.intValue, vipType: (account["vip_type"] as? NSNumber)?.intValue)
        }
        guard !formats.isEmpty else { throw AppError.message("没有可下载的音视频格式。请检查登录权限，或更新解析引擎后重试。") }
    }
}

/// Short-lived, memory-only extraction results. Never persisted with history.
struct AnalysisSnapshot {
    let url: String
    let auth: String
    let cookieFile: String
    let data: Data
    let created: Date
    func matches(url: String, auth: String, cookieFile: String, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(created)
        return self.url == url && self.auth == auth && self.cookieFile == cookieFile && age >= 0 && age < 120
    }
    func temporaryFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pickvideo-\(UUID().uuidString).info.json")
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AppError.message("无法准备视频信息，请重新解析后重试。")
        }
        return file
    }
}

struct DownloadOptions: Codable {
    var selection = "best"
    var exactFormat: String?
    var exactHasAudio = false
    var exactHasVideo = true
    var container = "auto"
    var subtitles = false
    var audioLanguage = ""
    var auth = "none"
    var cookieFile = ""
    var destination = ""
    var preview: MediaSummary?
    var accelerated: Bool?
    var selector: String {
        if let exactFormat { return exactHasVideo && !exactHasAudio ? "\(exactFormat)+bestaudio/\(exactFormat)" : exactFormat }
        let audio = audioLanguage.isEmpty ? "bestaudio" : "bestaudio[language=\(audioLanguage)]/bestaudio"
        if selection == "audio" || selection == "mp3" { return "bestaudio/best" }
        let filter: String
        let parts = selection.split(separator: ":")
        if [3, 4].contains(parts.count), parts[0] == "quality", let height = Int(parts[1]), let rate = Int(parts[2]) {
            let tier = parts.count == 4 ? Int(parts[3]).map { "[quality=\($0)]" } ?? "[quality=-99999]" : ""
            filter = "[height=\(height)]" + (rate > 0 ? "[fps>=\(Double(rate - 1) / 100)][fps<=\(Double(rate + 1) / 100)]" : "") + tier
        } else { filter = selection == "best" ? "" : "[height<=\(Int(selection) ?? 1080)]" }
        if audioLanguage.isEmpty { return "bestvideo\(filter)+bestaudio/best\(filter)" }
        return "bestvideo\(filter)+(\(audio))/best\(filter)"
    }
    var label: String { preview?.quality ?? exactFormat.map { "格式 \($0)" } ?? (selection == "best" ? "最佳画质 · 解析后显示详情" : selection == "audio" ? "原始音频" : selection == "mp3" ? "MP3 音频" : "\(selection)p") }
    func arguments(id: UUID, sourceURL: String = "") -> [String] {
        var a = ["--newline", "--no-quiet", "--progress", "--progress-delta", "0.5", "--no-simulate", "--no-overwrites", "--continue",
                 "--concurrent-fragments", "8", "--windows-filenames", "--trim-filenames", "180",
                 "--paths", destination,
                 "--output", "%(title).120B [%(id)s] [\(id.uuidString.prefix(8))].%(ext)s",
                 "--format", selector,
                 "--progress-template", "download:__PROGRESS__%(progress)j",
                 "--print", "before_dl:__TITLE__%(title)j",
                 "--print", "before_dl:__MEDIA__%(.{format_id,width,height,fps,vcodec,acodec,duration,filesize,filesize_approx,tbr,quality,format_note,format})j",
                 "--print", "after_move:__FILE__%(filepath)j"]
        if LinkParser.isBilibili(sourceURL) {
            // Bilibili DASH tracks share a clock but may have different starts.
            // Preserve that relationship: normalizing each input separately
            // advances video when its first timestamp is later than audio.
            a += ["--postprocessor-args", "Merger+ffmpeg_i1:-copyts"]
        }
        if accelerated == true, let aria2 = Tools.find("aria2c") {
            // yt-dlp's "http" protocol key covers HTTP and HTTPS.
            a += ["--downloader", "http:\(aria2)", "--downloader-args", "aria2c:--max-connection-per-server=8 --split=8 --min-split-size=1M --max-concurrent-downloads=1 --disable-ipv6=true --continue=true --auto-save-interval=1 --enable-color=false --human-readable=false --summary-interval=1 --console-log-level=warn --download-result=hide --connect-timeout=10 --timeout=20 --max-tries=5 --retry-wait=1"]
        }
        if selection == "mp3" { a += ["--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"] }
        else if selection == "audio" { a += ["--extract-audio"] }
        else if container != "auto" { a += ["--merge-output-format", container, "--remux-video", container] }
        if subtitles { a += ["--write-subs", "--sub-langs", "zh.*,en.*", "--sub-format", "srt/vtt/best"] }
        return a
    }
}

enum JobState: String, Codable {
    case queued, downloading, processing, completed, failed, cancelled, paused
    var title: String {
        switch self { case .queued: "等待下载"; case .downloading: "正在下载"; case .processing: "合并与整理"; case .completed: "已完成"; case .failed: "下载失败"; case .cancelled: "已取消"; case .paused: "已暂停" }
    }
    var isActive: Bool { self == .downloading || self == .processing }
}

struct DownloadJob: Identifiable, Codable {
    var id = UUID()
    var url: String
    var title: String
    var options: DownloadOptions
    var state: JobState = .queued
    var progress: Double = 0
    var speed = ""
    var eta = ""
    var phase = ""
    var error = ""
    var log = ""
    var files: [String] = []
    var createdAt = Date()
    var media: MediaSummary?
    var streamBytes: Double?
    var streamTotal: Double?
    var connections: Int?
}

struct AriaProgress {
    var downloaded: Double
    var total: Double
    var speed: Double
    var connections: Int
    static func parse(_ line: String) -> AriaProgress? {
        let pattern = #"\[#\w+\s+(\d+)B?/(\d+)B?\([^)]*\).*?CN:(\d+).*?DL:(\d+)B?"#
        guard let expression = try? NSRegularExpression(pattern: pattern), let m = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let ns = line as NSString
        guard let done = Double(ns.substring(with: m.range(at: 1))), let total = Double(ns.substring(with: m.range(at: 2))), let connections = Int(ns.substring(with: m.range(at: 3))), let speed = Double(ns.substring(with: m.range(at: 4))) else { return nil }
        return AriaProgress(downloaded: done, total: total, speed: speed, connections: connections)
    }
}

enum LoginNavigation {
    static func isExpectedInterruption(_ error: NSError) -> Bool {
        // WKWebView reports this policy interruption in the legacy error domain.
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["bilibili.com", "biligame.com", "b23.tv"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

enum Credentials {
    static let service = "app.pickvideo.credentials"
    static func argumentsAsync(auth: String, file: String) async throws -> ([String], URL?) {
        try await Task.detached(priority: .userInitiated) { try arguments(auth: auth, file: file) }.value
    }
    static func saveBilibiliAsync(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) { try saveBilibili(data) }.value
    }
    static func saveBilibili(_ data: Data) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "bilibili"]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AppError.message("无法将登录状态保存到 macOS 钥匙串。") }
        } else if status != errSecSuccess { throw AppError.message("无法更新钥匙串中的登录状态。") }
    }
    static func bilibili() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "bilibili", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    static func removeBilibili() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "bilibili"] as CFDictionary) }
    static func arguments(auth: String, file: String) throws -> ([String], URL?) {
        if auth == "bilibili" {
            guard let data = bilibili() else { throw AppError.message("Bilibili 登录状态不可用，请到「账号与设置」重新登录。") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pickvideo-\(UUID().uuidString).cookies")
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw AppError.message("无法创建临时登录文件。") }
            return (["--cookies", url.path], url)
        }
        if auth == "file" {
            guard FileManager.default.isReadableFile(atPath: file) else { throw AppError.message("Cookie 文件不可读取，请重新选择文件。") }
            // yt-dlp updates its cookie jar: always work on a temporary copy.
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pickvideo-\(UUID().uuidString).cookies")
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw AppError.message("无法创建临时登录文件。") }
            return (["--cookies", url.path], url)
        }
        if ["chrome", "edge", "firefox", "brave", "safari", "chromium"].contains(auth) { return (["--cookies-from-browser", auth], nil) }
        return ([], nil)
    }
}

/// Each engine runs in its own process group. Cancellation also reaches ffmpeg.
final class EngineRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        guard let p, p.isRunning else { return }
        let pid = p.processIdentifier
        // The worker establishes its process group before exec; fall back during startup.
        if getpgid(pid) == pid { kill(-pid, SIGINT) } else { p.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { p.terminate() } }
        }
    }
    func start(arguments: [String], timeout: Double? = nil, onLine: @escaping @Sendable (String) -> Void,
               completion: @escaping @Sendable (Int32, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let p = Process(), pipe = Pipe()
            p.executableURL = Tools.executable
            p.arguments = ["--engine-run", Tools.engine.path] + arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PYTHONUNBUFFERED"] = "1"; env["LC_ALL"] = "en_US.UTF-8"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            p.environment = env; p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); completion(-1, true); return }
            process = p
            do { try p.run(); lock.unlock() }
            catch { lock.unlock(); onLine(error.localizedDescription); completion(-1, false); return }
            let timer = DispatchWorkItem { [weak self] in self?.cancel() }
            if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
            var buffer = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let i = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let line = String(decoding: buffer[..<i], as: UTF8.self)
                    buffer.removeSubrange(...i); onLine(line)
                }
                if buffer.count > 32 * 1024 * 1024 { onLine("响应过大，已停止解析。"); cancel(); buffer.removeAll() }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            p.waitUntilExit(); timer.cancel()
            lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
            completion(p.terminationStatus, wasCancelled)
        }
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ text: String) { lock.lock(); lines.append(text); if lines.count > 400 { lines.removeFirst() }; lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

enum ErrorAdvice {
    static func explain(_ log: String) -> String {
        let lower = log.lowercased()
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") || lower.contains("keychain") {
            return "网站需要有效的登录状态。打开「账号与设置」，登录网站或选择已登录的浏览器，再重新解析。"
        }
        if lower.contains("403") || lower.contains("412") || lower.contains("429") || lower.contains("-352") {
            return "网站暂时拒绝了请求。请先在浏览器确认视频能播放，登录后再试；频繁请求时请稍后重试。"
        }
        if lower.contains("drm") { return "这个视频受 DRM 保护，当前无法下载。" }
        if lower.contains("unsupported url") { return "暂不支持这个链接。请使用视频播放页的完整链接，或更新解析引擎。" }
        if lower.contains("requested format") { return "这个画质当前不可用。请重新解析，查看最新画质；也可选择「最佳画质」。" }
        if lower.contains("no space") { return "保存位置空间不足。请更换文件夹或释放磁盘空间后重试。" }
        if lower.contains("timed out") || lower.contains("resolve") || lower.contains("network") { return "网络连接失败。请检查网络后重试。" }
        return String(log.split(separator: "\n").last(where: { $0.contains("ERROR") }) ?? log.split(separator: "\n").last ?? "下载未完成，请查看详细日志。")
    }
}
