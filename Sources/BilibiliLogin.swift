import Foundation
import Combine
import WebKit

/// Cookie events and navigation callbacks can both be missed during a redirect.
/// Poll only the local cookie store; contact Bilibili only after a session appears.
@MainActor
class LoginDetector: NSObject, ObservableObject {
    @Published var error = ""
    @Published var saving = false
    @Published var status = "请扫码，并在手机上确认登录；确认后会自动完成"
    var onAuthenticated: ((String) -> Void)?
    private(set) var finished = false
    private var checking = false
    private var polling: Task<Void, Never>?
    private var detection: Task<Void, Never>?
    private var verification: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private let pollInterval: UInt64
    private let retryDelay: TimeInterval
    private let cookies: @MainActor () async -> [HTTPCookie]
    private let verify: @MainActor ([HTTPCookie]) async throws -> String
    private let save: @MainActor (Data) async throws -> Void

    init(pollInterval: UInt64 = 1_000_000_000, retryDelay: TimeInterval = 5,
         cookies: @escaping @MainActor () async -> [HTTPCookie],
         verify: @escaping @MainActor ([HTTPCookie]) async throws -> String,
         save: @escaping @MainActor (Data) async throws -> Void) {
        self.pollInterval = pollInterval; self.retryDelay = retryDelay
        self.cookies = cookies; self.verify = verify; self.save = save
        super.init()
    }
    func startDetection() {
        guard !finished, polling == nil else { return }
        let interval = pollInterval
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.finished == false else { return }
                self?.checkLogin(manual: false)
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
            }
        }
    }
    func scheduleDetection() {
        guard !finished else { return }
        detection?.cancel()
        detection = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            self?.checkLogin(manual: false)
        }
    }
    func stop() {
        finished = true; polling?.cancel(); detection?.cancel(); verification?.cancel()
        polling = nil; detection = nil; verification = nil
        onAuthenticated = nil
    }
    func navigationFailed(_ failure: Error) {
        guard !finished else { return }
        scheduleDetection()
        if LoginNavigation.isExpectedInterruption(failure as NSError) {
            if !saving { status = "正在检查扫码后的登录状态…" }
            return
        }
        error = "登录网页暂时未能加载：\(failure.localizedDescription)。仍会自动检查登录状态，可稍后重新加载。"
    }
    func checkLogin(manual: Bool) {
        guard !checking, !finished else { return }
        checking = true
        if manual { error = "" }
        verification = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.checking = false; self.saving = false }
            let all = await self.cookies()
            guard !self.finished, !Task.isCancelled else { return }
            let relevant = all.filter {
                let domain = $0.domain.lowercased()
                return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
            }
            guard relevant.contains(where: {
                $0.name == "SESSDATA" && !$0.value.isEmpty && ($0.expiresDate == nil || $0.expiresDate! > Date())
            }) else {
                if manual { self.error = "尚未收到有效登录状态。请在手机上确认登录，系统会继续自动检测。" }
                return
            }
            guard manual || Date() >= self.retryAfter else { return }
            self.saving = true; self.error = ""
            self.status = "已收到登录状态，正在向 Bilibili 核验…"
            do {
                let name = try await self.verify(relevant)
                guard !self.finished, !Task.isCancelled else { return }
                let rows = relevant.map { c in
                    [c.isHTTPOnly ? "#HttpOnly_" + c.domain : c.domain,
                     c.domain.hasPrefix(".") ? "TRUE" : "FALSE", c.path,
                     c.isSecure ? "TRUE" : "FALSE", String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)),
                     c.name, c.value].joined(separator: "\t")
                }
                let text = "# Netscape HTTP Cookie File\n" + rows.joined(separator: "\n") + "\n"
                try await self.save(Data(text.utf8))
                guard !self.finished, !Task.isCancelled else { return }
                self.finished = true; self.polling?.cancel(); self.detection?.cancel()
                self.error = ""; self.status = "已识别登录：\(name)"
                self.onAuthenticated?(name)
            } catch {
                guard !self.finished, !Task.isCancelled else { return }
                self.retryAfter = Date().addingTimeInterval(self.retryDelay)
                self.status = "已收到登录状态，正在等待核验重试"
                self.error = "\(error.localizedDescription) 将自动重试，也可点击「重新检测」。"
            }
        }
    }
}

@MainActor
final class LoginSession: LoginDetector, WKHTTPCookieStoreObserver {
    let web: WKWebView
    init() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.pageZoom = 0.75; web = view
        super.init(cookies: {
            await withCheckedContinuation { continuation in
                view.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
        }, verify: { try await BilibiliLoginVerifier.account(for: $0) },
           save: { try await Credentials.saveBilibiliAsync($0) })
        view.configuration.websiteDataStore.httpCookieStore.add(self)
        view.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { scheduleDetection() }
    override func stop() {
        super.stop(); web.stopLoading()
        web.configuration.websiteDataStore.httpCookieStore.remove(self)
    }
}

enum BilibiliLoginVerifier {
    static func account(for cookies: [HTTPCookie]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        request.timeoutInterval = 15; request.httpShouldHandleCookies = false
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let (data, reply) = try await network.data(for: request)
        guard (reply as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("Bilibili 登录核验暂时未能连接。")
        }
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let account = response?["data"] as? [String: Any], account["isLogin"] as? Bool == true else {
            throw AppError.message("Bilibili 尚未确认账号登录，请完成手机上的确认或验证。")
        }
        return account["uname"] as? String ?? "Bilibili 账号"
    }
}
