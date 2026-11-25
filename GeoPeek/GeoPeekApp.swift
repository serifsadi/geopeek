//
//  GeoPeekApp.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import Darwin
import SwiftUI

private let viewerWindowID = "viewer"

@main
@MainActor
struct GeoPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = appDelegate.install(openWindow)
        WindowGroup(id: viewerWindowID, for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
        }
        // The delegate opens one window per file. An empty set keeps SwiftUI
        // from also creating a window for the same external event.
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands { ViewerCommands() }
    }
}

@MainActor
struct ViewerCommands: Commands {
    @FocusedValue(\.fileURL) private var focusedFile
    @FocusedValue(\.windowLoad) private var windowLoad
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let urls = RecentFiles.shared.urls
        let setDefaultDisabled = DefaultApplication.shared.isDefaultForAll
            || DefaultApplication.shared.isSetting
        CommandGroup(after: .appInfo) {
            Button("Set as Default…") {
                Task { await DefaultApplication.shared.setAsDefault() }
            }
            .disabled(setDefaultDisabled)
        }
        CommandGroup(after: .newItem) {
            Button("Open File…") {
                if let focusedFile, let windowLoad {
                    openDocument(into: focusedFile, load: windowLoad)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(focusedFile == nil || windowLoad == nil)
            // A WindowGroup app does not get the document Open Recent menu.
            Menu("Open Recent") {
                if urls.isEmpty {
                    Button("Clear Menu") {}
                        .disabled(true)
                } else {
                    ForEach(urls, id: \.absoluteString) { url in
                        Button(url.lastPathComponent) { openRecent(url, openWindow: openWindow) }
                    }
                    Divider()
                    Button("Clear Menu") { RecentFiles.shared.clear() }
                }
            }
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Paste GeoJSON") {
                if let focusedFile, let windowLoad {
                    pasteGeoJSON(into: focusedFile, load: windowLoad)
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(focusedFile == nil || windowLoad == nil)
        }
        // The system About panel stays in the app menu. These items replace
        // the default Help item, which looks for a help book this app does not have.
        CommandGroup(replacing: .help) {
            Button("Acknowledgements") {
                showAcknowledgements()
            }
            Button("Support") {
                openWebLink("https://geopeek.app/support/")
            }
            Button("Privacy Policy") {
                openWebLink("https://geopeek.app/privacy/")
            }
        }
    }
}

@MainActor
private func openWebLink(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}

/// The bundled license text, in a window this process owns. Reading the app
/// bundle does not need a user-selected file or another app.
@MainActor
func showAcknowledgements() {
    AcknowledgementsWindow.show()
}

@MainActor
private enum AcknowledgementsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: AcknowledgementsView(text: loadText()))
            let created = NSWindow(contentViewController: host)
            created.title = "Acknowledgements"
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 560, height: 480))
            created.contentMinSize = NSSize(width: 420, height: 280)
            created.isReleasedWhenClosed = false
            created.isRestorable = false
            created.tabbingMode = .disallowed
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func loadText() -> String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return "The acknowledgements file is not in this copy of GeoPeek."
        }
        return text
    }
}

private struct AcknowledgementsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FocusedValues {
    @Entry var fileURL: Binding<URL?>?
    @Entry var windowLoad: WindowLoad?
}

@MainActor
func openRecent(_ url: URL, openWindow: OpenWindowAction) {
    openWindow(value: url)
}

/// Finder and `open` deliver every URL here. `openWindow` creates a window
/// for each one, or brings forward the window that already has that URL.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindow: OpenWindowAction?
    private var queued: [URL] = []
    private var launchedWithFile = false
    private var finishedLaunching = false
    private var pendingWelcome = false

    func install(_ openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        if !queued.isEmpty {
            let urls = queued
            queued.removeAll()
            present(urls)
        }
        if pendingWelcome {
            pendingWelcome = false
            openWelcome()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if !launchedWithFile {
            openWelcome()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        RecentFiles.shared.refresh()
        DefaultApplication.shared.refresh()
    }

    /// Suppressed launch behavior does not open a window for a Dock click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag || !finishedLaunching { return true }
        openWindow?(id: viewerWindowID)
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(isSupportedDocument)
        // A cold launch delivers the file URLs before didFinishLaunching.
        if !finishedLaunching, !files.isEmpty {
            launchedWithFile = true
        }
        guard !files.isEmpty else { return }
        guard openWindow != nil else {
            queued.append(contentsOf: files)
            return
        }
        present(files)
    }

    private func present(_ urls: [URL]) {
        guard let openWindow else { return }
        urls.forEach { openWindow(value: $0) }
    }

    private func openWelcome() {
        guard !launchedWithFile else { return }
        guard let openWindow else {
            pendingWelcome = true
            return
        }
        openWindow(id: viewerWindowID)
    }
}

/// Recent files, and the security-scoped bookmarks AppKit stores for them.
@MainActor
@Observable
final class RecentFiles {
    static let shared = RecentFiles()

    private(set) var urls: [URL] = []
    private var openDates: [String: Date] = [:]

    private init() { refresh() }

    func note(_ url: URL) {
        guard !Self.isTemporary(url) else { return }
        Self.writeBookmark(url)
        var dates = Self.loadDates()
        dates[Self.key(for: url)] = Date().timeIntervalSince1970
        Self.storeDates(dates)
        refresh()
    }

    /// Document recents have no per-item remove, so the list is cleared and the
    /// kept URLs are noted again, oldest first. The last note is the newest and
    /// ends up at the top.
    ///
    /// `clearRecentDocuments(_:)` leaves `recentDocumentURLs` empty. The next
    /// `noteNewRecentDocumentURL(_:)` is the call that brings that empty list
    /// back, and the URL passed to it is not added. Every later note is added.
    /// Noting oldest first makes the missing URL the oldest file, so Remove
    /// from Recents also deletes the bottom row, in the welcome list and in
    /// File > Open Recent, including after relaunch. The list is read back.
    /// When it is not the kept URLs, they are noted again. That first note has
    /// already been consumed, so this pass inserts every URL, still oldest
    /// first. Open dates of the kept files are left unchanged.
    func remove(_ url: URL) {
        let path = Self.key(for: url)
        let controller = NSDocumentController.shared
        let remaining = controller.recentDocumentURLs.filter { Self.key(for: $0) != path }
        let wanted = remaining.map { Self.key(for: $0) }
        controller.clearRecentDocuments(nil)
        Self.noteOldestFirst(remaining)
        // The first note was the oldest URL. If that note was not added, the
        // native list is not the kept URLs, and the second pass puts it back.
        if controller.recentDocumentURLs.map({ Self.key(for: $0) }) != wanted {
            Self.noteOldestFirst(remaining)
        }
        var dates = Self.loadDates()
        dates.removeValue(forKey: path)
        Self.storeDates(dates)
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        UserDefaults.standard.removeObject(forKey: Self.datesKey)
        urls = []
        openDates = [:]
    }

    func refresh() {
        let recent = NSDocumentController.shared.recentDocumentURLs
        urls = recent.filter { !Self.isTemporary($0) && Self.exists($0) }
        let stored = Self.loadDates()
        var dates: [String: Date] = [:]
        for url in urls {
            let key = Self.key(for: url)
            if let interval = stored[key] {
                dates[key] = Date(timeIntervalSince1970: interval)
            }
        }
        openDates = dates
    }

    func openedAt(for url: URL) -> Date? {
        openDates[Self.key(for: url)]
    }

    /// `NSHomeDirectory()` is the sandbox container. The real home comes from the password database.
    func abbreviatedParentPath(for url: URL) -> String {
        let path = url.deletingLastPathComponent().standardizedFileURL.path
        let home = Self.homeDirectory
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + String(path.dropFirst(prefix.count))
    }

    /// The bookmarked recent URL first. A restored URL can compare equal and still have no bookmark.
    func accessCandidates(for url: URL) -> [URL] {
        let path = url.standardizedFileURL.path
        guard let recent = NSDocumentController.shared.recentDocumentURLs.first(where: {
            $0.standardizedFileURL.path == path
        }) else { return [url] }
        return [recent, url]
    }

    private static let datesKey = "recentOpenDates"

    private static let homeDirectory: String = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return "" }
        var path = String(cString: directory)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }()

    private static func loadDates() -> [String: TimeInterval] {
        guard let stored = UserDefaults.standard.dictionary(forKey: datesKey) else { return [:] }
        var dates: [String: TimeInterval] = [:]
        for (key, value) in stored {
            if let interval = value as? TimeInterval {
                dates[key] = interval
            }
        }
        return dates
    }

    private static func storeDates(_ dates: [String: TimeInterval]) {
        UserDefaults.standard.set(dates, forKey: datesKey)
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func noteOldestFirst(_ urls: [URL]) {
        for url in urls.reversed() {
            writeBookmark(url)
        }
    }

    private static func writeBookmark(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if started { url.stopAccessingSecurityScopedResource() }
    }

    private static func isTemporary(_ url: URL) -> Bool {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(temporary)
    }

    private static func exists(_ url: URL) -> Bool {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.checkResourceIsReachable()
        } catch let error as NSError {
            let missing = error.domain == NSCocoaErrorDomain
                && (error.code == CocoaError.fileReadNoSuchFile.rawValue
                    || error.code == CocoaError.fileNoSuchFile.rawValue)
            return !missing
        }
    }
}
