import AppKit
import XCTest
@testable import Search

@MainActor
final class BrowserChromeTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "chrome-tests-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        let world = "chrome-tests-\(getpid())"
        if Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(world)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        unsetenv("SEARCH_PROBE")
        super.tearDown()
    }

    private func browser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return Browser(record: WindowRecord())
    }

    func testFullAddressPreservesSchemePathQueryFragmentAndRedactsCredentials() throws {
        let address = "https://www.example.com/path%20name?q=one%26two#map=15/23/58"
        XCTAssertEqual(Browser.visibleAddress(URL(string: address)), address)
        XCTAssertEqual(Browser.visibleAddress(URL(string: "https://user:secret@example.com/path?q=1#fragment")), "https://example.com/path?q=1#fragment")
        XCTAssertEqual(Browser.visibleAddress(nil), "")
    }

    func testReselectingPinDismissesDraftWithoutGoingHome() throws {
        let browser = browser()
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        tab.restore(url: URL(string: "about:blank#current")!, title: "Current")
        browser.pin(tab)
        tab.home = URL(string: "about:blank#home")
        browser.edit()
        browser.typed = "unfinished draft"
        browser.select(tab)
        XCTAssertFalse(browser.editing)
        XCTAssertEqual(browser.typed, "")
        XCTAssertEqual(Browser.visibleAddress(tab.address), "about:blank#current")
    }

    func testCloseUnpinnedUndoPreservesOrderPinsPrivateStoreAndBlankDraft() throws {
        let browser = browser()
        browser.newTab()
        let pin = try XCTUnwrap(browser.active)
        pin.restore(url: URL(string: "about:blank#pin")!, title: "Pin")
        browser.pin(pin)
        browser.newTab()
        let regular = try XCTUnwrap(browser.active)
        regular.restore(url: URL(string: "about:blank#regular")!, title: "Regular")
        browser.newShyTab()
        let shy = try XCTUnwrap(browser.active)
        let store = shy.store
        shy.draft = "private draft"
        browser.typed = "private draft"
        let order = browser.tabs.map(\.id)
        let ghosts = browser.ghosts
        browser.closeUnpinnedTabs()
        XCTAssertTrue(browser.tabs.contains { $0 === pin })
        XCTAssertFalse(browser.tabs.contains { $0 === shy || $0 === regular })
        XCTAssertTrue(browser.canUndoCloseUnpinnedTabs)
        XCTAssertEqual(browser.ghosts, ghosts)
        browser.undoCloseUnpinnedTabs()
        XCTAssertEqual(browser.tabs.map(\.id), order)
        XCTAssertEqual(browser.activeID, shy.id)
        XCTAssertTrue(shy.shy)
        XCTAssertTrue(shy.store === store)
        XCTAssertFalse(shy.store.isPersistent)
        XCTAssertEqual(shy.draft, "private draft")
        XCTAssertNotNil(pin.pin)
        XCTAssertFalse(browser.canUndoCloseUnpinnedTabs)
    }

    func testUndoPreservesGroupsAndSplitLayout() throws {
        let browser = browser()
        let oldSplit = browser.prefs.splitView
        let oldGroups = browser.prefs.usesTabGroups
        browser.prefs.splitView = true
        browser.prefs.usesTabGroups = true
        defer { browser.prefs.splitView = oldSplit; browser.prefs.usesTabGroups = oldGroups }
        browser.newTab()
        let first = try XCTUnwrap(browser.active)
        first.restore(url: URL(string: "about:blank#first")!, title: "First")
        let group = browser.addTabGroup(containing: first)
        browser.newTab()
        let second = try XCTUnwrap(browser.active)
        second.restore(url: URL(string: "about:blank#second")!, title: "Second")
        browser.move(second, toGroup: group)
        browser.pair(first, with: second, onLeft: true)
        let pairs = browser.splits
        let groups = browser.tabGroups
        let order = browser.tabs.map(\.id)
        browser.closeUnpinnedTabs()
        browser.undoCloseUnpinnedTabs()
        XCTAssertEqual(browser.tabs.map(\.id), order)
        XCTAssertEqual(browser.splits, pairs)
        XCTAssertEqual(browser.tabGroups, groups)
    }

    func testUndoKeepsNewTabsCreatedAfterClosing() throws {
        let browser = browser()
        browser.newTab()
        let original = try XCTUnwrap(browser.active)
        original.restore(url: URL(string: "about:blank#original")!, title: "Original")
        let order = browser.tabs.map(\.id)
        browser.closeUnpinnedTabs()
        let replacement = try XCTUnwrap(browser.active)
        replacement.restore(url: URL(string: "about:blank#new")!, title: "New")
        browser.undoCloseUnpinnedTabs()
        XCTAssertEqual(browser.tabs.map(\.id), order + [replacement.id])
    }
}
