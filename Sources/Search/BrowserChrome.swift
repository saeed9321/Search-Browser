import SwiftUI
import AppKit

struct BrowserChrome: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            TabBar(browser: browser)
            NavigationRow(browser: browser)
        }
        .background(Palette.ground)
    }
}

struct NavigationRow: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 12) {
            Helm(browser: browser)
            if let tab = browser.active {
                CurrentAddress(browser: browser, tab: tab)
            } else {
                Button("Search or enter an address") { browser.newTab() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                BookmarkDoor(browser: browser, arrowEdge: .bottom)
                FetchDoor(browser: browser, fetches: browser.fetches)
                ExtensionSlot()
                Menu {
                    Button("New tab") { browser.newTab() }
                    Button("New private tab") { browser.newShyTab() }
                    Divider()
                    Button("Close unpinned tabs") { browser.closeUnpinnedTabs() }
                        .disabled(!browser.tabs.contains { $0.pin == nil && !$0.bench })
                    if browser.canUndoCloseUnpinnedTabs {
                        Button("Undo close unpinned tabs") { browser.undoCloseUnpinnedTabs() }
                    }
                    Divider()
                    Button("Settings…") { browser.tuning = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Browser tools")
                .help("Browser tools")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.navigation)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .overlay(alignment: .topTrailing) {
            if browser.canUndoCloseUnpinnedTabs {
                HStack(spacing: 12) {
                    Text("Unpinned tabs closed")
                        .foregroundStyle(Palette.ink)
                    Button("Undo") { browser.undoCloseUnpinnedTabs() }
                        .accessibilityLabel("Undo close unpinned tabs")
                }
                .font(.system(size: 13))
                .padding(12)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.trailing, 12)
                .offset(y: Metrics.navigation + 8)
            }
        }
    }
}

private struct CurrentAddress: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @State private var expanded = false

    private var address: String { Browser.visibleAddress(tab.address) }

    var body: some View {
        HStack(spacing: 8) {
            Button { browser.edit() } label: {
                HStack(spacing: 8) {
                    Image(systemName: tab.isBlank ? "magnifyingglass" : "globe")
                        .foregroundStyle(Palette.muted)
                    Text(address.isEmpty ? "Search or enter an address" : address)
                        .foregroundStyle(address.isEmpty ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel("Search or enter an address")
            .accessibilityValue(address)
            .help(address.isEmpty ? "Search or enter an address" : address)
            if !address.isEmpty {
                Door(icon: "doc.on.doc", help: "Copy URL") { copy() }
                Door(icon: "arrow.up.left.and.arrow.down.right", help: "Show full address") { expanded.toggle() }
                    .popover(isPresented: $expanded, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Full address").font(.headline)
                            ScrollView {
                                Text(address)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            HStack {
                                Button("Copy URL") { copy() }
                                Spacer()
                                Button("Done") { expanded = false }
                                    .keyboardShortcut(.cancelAction)
                            }
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(18)
                        .frame(width: 520)
                        .background(Palette.ground)
                    }
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))
        .onChange(of: tab.id) { _, _ in expanded = false }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        browser.announce("Address copied")
    }
}
