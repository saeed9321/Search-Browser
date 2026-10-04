import AppKit
import CoreLocation
import WebKit
import XCTest
@testable import Search

@MainActor
final class GeolocationTests: XCTestCase {
    private final class FrameReceiver: NSObject, WKScriptMessageHandler {
        var frame: WKFrameInfo?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            frame = message.frameInfo
        }
    }

    private final class ConsentingDelegate: NSObject, WKUIDelegate {
        var requests = 0
        @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
        func location(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                      decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            requests += 1
            decisionHandler(.grant)
        }
    }

    override class func setUp() {
        setenv("SEARCH_PROBE", "location-tests-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        let world = "location-tests-\(getpid())"
        if Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            let suite = "com.officecommun.search.test.\(world)"
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        unsetenv("SEARCH_PROBE")
        super.tearDown()
    }

    func testWebsiteConsentIsRequiredAndAllowOnceIsNotSaved() async throws {
        try await checkConsent(shy: false)
    }

    func testPrivateLocationChoicesAreNeverReusedOrSaved() async throws {
        try await checkConsent(shy: true)
    }

    private func checkConsent(shy: Bool) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        if shy { browser.newShyTab() } else { browser.newTab() }
        let tab = try XCTUnwrap(browser.active)
        let web = tab.web
        let receiver = FrameReceiver()
        web.configuration.userContentController.add(receiver, contentWorld: .defaultClient, name: "locationFrame")
        defer { web.configuration.userContentController.removeScriptMessageHandler(forName: "locationFrame", contentWorld: .defaultClient) }
        let server = try LocalDownloadServer(size: 1024)
        defer { server.stop() }
        web.load(URLRequest(url: server.url("/page")))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        web.evaluateJavaScript("window.webkit.messageHandlers.locationFrame.postMessage('frame')", in: nil, in: .defaultClient)
        for _ in 0..<100 where receiver.frame == nil { try await Task.sleep(for: .milliseconds(50)) }
        let frame = try XCTUnwrap(receiver.frame)
        let key = "capture." + Browser.origin("http", "127.0.0.1", Int(server.port)) + "|location"
        defer { Store.settings.removeObject(forKey: key) }
        if shy { Store.settings.set(true, forKey: key) }
        var answer: WKPermissionDecision?
        browser.askedForLocation(web, origin: frame.securityOrigin, frame: frame) { answer = $0 }
        XCTAssertNil(answer)
        XCTAssertEqual(browser.asking?.wants, "location")
        if shy { Store.settings.removeObject(forKey: key) }
        try await Task.sleep(for: .milliseconds(550))
        browser.allowCaptureOnce()
        XCTAssertEqual(Browser.locationAnswered, "granted")
        XCTAssertEqual(answer, .deny, "Test runs must never ask macOS for location")
        XCTAssertNil(Store.settings.object(forKey: key))

        browser.askedForLocation(web, origin: frame.securityOrigin, frame: frame) { answer = $0 }
        XCTAssertEqual(browser.asking?.wants, "location")
        try await Task.sleep(for: .milliseconds(550))
        browser.denyCapture()
        if shy {
            XCTAssertNil(Store.settings.object(forKey: key))
        } else {
            XCTAssertEqual(Store.settings.object(forKey: key) as? Bool, false)
            browser.askedForLocation(web, origin: frame.securityOrigin, frame: frame) { answer = $0 }
            XCTAssertNil(browser.asking)
            XCTAssertEqual(Browser.locationAnswered, "denied")
            Store.settings.set(true, forKey: key)
            browser.askedForLocation(web, origin: frame.securityOrigin, frame: frame) { answer = $0 }
            XCTAssertNil(browser.asking)
            XCTAssertEqual(Browser.locationAnswered, "granted")
        }
        browser.newTab()
        browser.askedForLocation(web, origin: frame.securityOrigin, frame: frame) { answer = $0 }
        XCTAssertEqual(Browser.locationAnswered, "denied")
        XCTAssertNil(browser.asking)
    }

    func testWebKitFindsTheLocationPermissionDelegate() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:")))
    }

    func testWebsitesReachTheLocationPrompt() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let web = tab.web
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        window.contentView = web
        window.orderFront(nil)
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
        }
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let server = try LocalDownloadServer(size: 1024)
        defer { server.stop() }
        web.load(URLRequest(url: server.url("/page")))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await web.evaluateJavaScript("navigator.geolocation.getCurrentPosition(() => { window.locationResult = 'success'; }, e => { window.locationResult = e.code + ': ' + e.message; }); undefined")
        for _ in 0..<100 where browser.asking == nil { try await Task.sleep(for: .milliseconds(50)) }
        let result = try await web.evaluateJavaScript("JSON.stringify({result: window.locationResult || 'waiting', visibility: document.visibilityState, secure: window.isSecureContext})")
        XCTAssertEqual(browser.asking?.wants, "location", String(describing: result))
        if browser.asking != nil {
            try await Task.sleep(for: .milliseconds(550))
            browser.denyCapture()
        }
    }

    func testMissingMacProviderTimesOutAfterSiteConsent() async throws {
        try await checkProvider(installed: false)
    }

    func testMacProviderDeliversPositionAndStopsAfterUse() async throws {
        try await checkProvider(installed: true)
    }

    func testMacProviderForwardsLocationErrors() async throws {
        try await checkProvider(installed: true, fail: true)
    }

    private func checkProvider(installed: Bool, fail: Bool = false) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let consent = ConsentingDelegate()
        web.uiDelegate = consent
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
        }
        if installed { XCTAssertTrue(PageLocations.provide(web)) }
        let server = try LocalDownloadServer(size: 1024)
        defer { server.stop() }
        web.load(URLRequest(url: server.url("/page")))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await web.evaluateJavaScript("""
            navigator.geolocation.getCurrentPosition(p => {
                window.gpsResult = { latitude: p.coords.latitude, longitude: p.coords.longitude,
                                     accuracy: p.coords.accuracy, altitude: p.coords.altitude,
                                     heading: p.coords.heading, speed: p.coords.speed };
            }, e => { window.gpsResult = { error: e.code }; }, { timeout: 1500 }); undefined
            """)
        if installed {
            for _ in 0..<100 where !PageLocations.updating { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(PageLocations.updating)
            if fail {
                PageLocations.failed()
            } else {
                PageLocations.changed(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 12, longitude: 34),
                                                 altitude: 50, horizontalAccuracy: 5, verticalAccuracy: 6,
                                                 course: 7, speed: 8, timestamp: Date()))
            }
        }
        var result: [String: Double]?
        for _ in 0..<100 where result == nil {
            result = try await web.evaluateJavaScript("window.gpsResult || null") as? [String: Double]
            if result == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(consent.requests, 1)
        if !installed {
            XCTAssertEqual(result?["error"], 3, "Without a macOS provider, site consent alone never returns a position")
        } else if fail {
            XCTAssertEqual(result?["error"], 2)
        } else {
            XCTAssertEqual(result, ["latitude": 12, "longitude": 34, "accuracy": 5, "altitude": 50, "heading": 7, "speed": 8])
        }
        for _ in 0..<100 where PageLocations.updating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(PageLocations.updating)
    }
}
