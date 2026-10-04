import XCTest
import AppKit
import WebKit
@testable import Search

final class PointerLockTests: XCTestCase {
    private static var probeWorld: String?

    override class func setUp() {
        super.setUp()
        let world = "pointer-tests-\(UUID().uuidString.lowercased())"
        probeWorld = world
        setenv("SEARCH_PROBE", world, 1)
    }

    override class func tearDown() {
        Disk.drain()
        if let probeWorld, Store.world == probeWorld {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(probeWorld)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(probeWorld)")
        }
        unsetenv("SEARCH_PROBE")
        super.tearDown()
    }

    /// WebKit finds these by name alone; a misspelt one is never called and
    /// every game is refused the pointer without a word.
    @MainActor func testWebKitFindsThePointerLockAnswers() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("_webViewDidRequestPointerLock:completionHandler:")))
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("_webViewDidLosePointerLock:")))
    }

    /// A page that isn't the tab in front doesn't get the pointer.
    @MainActor func testAPageOutsideTheFrontTabIsRefused() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        var granted: Bool?
        browser.askedForPointer(WKWebView(), completionHandler: { granted = $0 })
        XCTAssertEqual(granted, false)
        XCTAssertNil(browser.pointerLocked)
        XCTAssertFalse(browser.releasePointer())
    }

    /// WebKit on this Mac offers pages the pointer lock API at all.
    @MainActor func testPagesCanAskForThePointer() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        web.loadHTMLString("<canvas></canvas>", baseURL: URL(string: "https://game.example/"))
        for _ in 0..<50 where web.isLoading { try await Task.sleep(for: .milliseconds(100)) }
        let kind = try await web.evaluateJavaScript("typeof document.body.requestPointerLock") as? String
        XCTAssertEqual(kind, "function")
    }
}
