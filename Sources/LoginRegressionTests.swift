import Foundation

/// Tests the production detector with a local cookie source and a fake verifier.
/// No account, keychain or network is used by this test entry point.
@MainActor
enum LoginRegressionTests {
    static func run() async {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(name)")
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
            guard condition() else { fputs("FAIL: timed out waiting for detector\n", stderr); exit(1) }
        }
        func cookie(domain: String = ".bilibili.com", value: String = "fixture",
                    expires: Date = Date().addingTimeInterval(3600)) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: "SESSDATA", .value: value,
                                   .secure: "TRUE", .expires: expires])!
        }

        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        check(LoginNavigation.isExpectedInterruption(interrupted), "recognize the reported WebKit frame interruption")
        check(!LoginNavigation.isExpectedInterruption(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
              && !LoginNavigation.isExpectedInterruption(NSError(domain: "other", code: interrupted.code)),
              "keep real network errors and unrelated error domains visible")

        var localCookies = [cookie(domain: ".bilibili.com.attacker.test"),
                            cookie(expires: Date().addingTimeInterval(-60)), cookie(value: "")]
        var reads = 0, verifications = 0, saves = 0, callbacks = 0
        var verificationGate: CheckedContinuation<String, Never>?
        let detector = LoginDetector(pollInterval: 20_000_000, retryDelay: 0.02, cookies: {
            reads += 1; return localCookies
        }, verify: { relevant in
            verifications += 1
            check(relevant.count == 1 && relevant[0].domain == ".bilibili.com", "verify only the account site's cookies")
            return await withCheckedContinuation { verificationGate = $0 }
        }, save: { data in
            saves += 1
            let text = String(decoding: data, as: UTF8.self)
            check(text.hasPrefix("# Netscape HTTP Cookie File\n") && !text.contains("attacker.test"), "persist only the verified site's cookie jar")
        })
        detector.onAuthenticated = { _ in callbacks += 1 }
        detector.startDetection()
        await waitUntil { reads >= 2 }
        check(verifications == 0 && saves == 0 && callbacks == 0, "expired, empty and foreign cookies cannot authenticate")

        // Reproduce the screenshot: interrupted navigation, followed by cookies,
        // with no cookiesDidChange or didFinish notification at all.
        detector.navigationFailed(interrupted)
        check(detector.error.isEmpty && !detector.finished, "interrupted navigation neither fails nor falsely succeeds")
        localCookies = [cookie(), cookie(domain: ".bilibili.com.attacker.test")]
        await waitUntil { verificationGate != nil }
        check(detector.saving && callbacks == 0 && saves == 0, "polling finds delayed credentials but waits for account verification")
        verificationGate?.resume(returning: "test account"); verificationGate = nil
        await waitUntil { callbacks == 1 }
        check(detector.finished && saves == 1 && detector.error.isEmpty, "verified login completes automatically without manual detection")
        detector.checkLogin(manual: true); detector.scheduleDetection(); detector.startDetection()
        try? await Task.sleep(nanoseconds: 60_000_000)
        check(callbacks == 1 && verifications == 1 && saves == 1, "completed login stops polling and cannot save or notify twice")
        detector.stop()

        var attempts = 0, retrySaves = 0, retryCallbacks = 0
        var retryGate: CheckedContinuation<String, Never>?
        let retrying = LoginDetector(pollInterval: 20_000_000, retryDelay: 0.02, cookies: { [cookie()] }, verify: { _ in
            attempts += 1
            if attempts == 1 { throw AppError.message("simulated verification timeout") }
            return await withCheckedContinuation { retryGate = $0 }
        }, save: { _ in retrySaves += 1 })
        retrying.onAuthenticated = { _ in retryCallbacks += 1 }
        retrying.startDetection()
        await waitUntil { retryGate != nil }
        check(retrySaves == 0 && retryCallbacks == 0, "failed account verification cannot persist or report a login")
        retryGate?.resume(returning: "test account"); retryGate = nil
        await waitUntil { retryCallbacks == 1 }
        check(attempts == 2 && retrySaves == 1 && retrying.error.isEmpty, "temporary verification failure retries automatically and clears the error")
        retrying.stop()

        var lateGate: CheckedContinuation<String, Never>?
        var lateSaves = 0, lateCallbacks = 0
        let closing = LoginDetector(pollInterval: 20_000_000, cookies: { [cookie()] }, verify: { _ in
            await withCheckedContinuation { lateGate = $0 }
        }, save: { _ in lateSaves += 1 })
        closing.onAuthenticated = { _ in lateCallbacks += 1 }
        closing.startDetection()
        await waitUntil { lateGate != nil }
        closing.stop(); lateGate?.resume(returning: "test account"); lateGate = nil
        await waitUntil { !closing.saving }
        check(lateSaves == 0 && lateCallbacks == 0, "closing during verification prevents late saving and callbacks")

        var cookieGate: CheckedContinuation<[HTTPCookie], Never>?
        var lateVerifications = 0
        let closingBeforeCookies = LoginDetector(pollInterval: 20_000_000, cookies: {
            await withCheckedContinuation { cookieGate = $0 }
        }, verify: { _ in lateVerifications += 1; return "test account" }, save: { _ in
            check(false, "closed cookie request must never save")
        })
        closingBeforeCookies.startDetection()
        await waitUntil { cookieGate != nil }
        closingBeforeCookies.stop(); cookieGate?.resume(returning: [cookie()]); cookieGate = nil
        try? await Task.sleep(nanoseconds: 60_000_000)
        check(lateVerifications == 0, "closing during cookie retrieval prevents a late network request")

        print("\(checks) login regression checks passed.")
        exit(0)
    }
}
