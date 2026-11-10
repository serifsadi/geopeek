//
//  GeoPeekApp.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import Darwin
import SwiftUI

@main
struct GeoPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = appDelegate.install(openWindow)
        WindowGroup(for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
        }
        // The delegate opens one window per file. An empty set keeps SwiftUI
        // from also creating a window for the same external event.
        .handlesExternalEvents(matching: [])
        .commands { ViewerCommands() }
    }
}

struct ViewerCommands: Commands {
    @FocusedValue(\.fileURL) private var focusedFile
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let urls = RecentFiles.shared.urls
        CommandGroup(after: .newItem) {
            Button("Open GeoJSON File…") {
                if let focusedFile { openGeoJSONFile(into: focusedFile) }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(focusedFile == nil)
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
                if let focusedFile { pasteGeoJSON(into: focusedFile) }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(focusedFile == nil)
        }
    }
}

extension FocusedValues {
    @Entry var fileURL: Binding<URL?>?
}

func openRecent(_ url: URL, openWindow: OpenWindowAction) {
    RecentFiles.shared.note(url)
    openWindow(value: url)
}

/// Finder and `open` deliver every URL here. `openWindow` creates a window
/// for each one, or brings forward the window that already has that URL.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindow: OpenWindowAction?
    private var queued: [URL] = []

    func install(_ openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        guard !queued.isEmpty else { return }
        let urls = queued
        queued.removeAll()
        present(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        RecentFiles.shared.refresh()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(isGeoJSONFile)
        files.forEach { RecentFiles.shared.note($0) }
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

    /// Document recents have no per-item remove, so the list is cleared and the others are noted again, oldest first.
    func remove(_ url: URL) {
        let path = Self.key(for: url)
        let remaining = NSDocumentController.shared.recentDocumentURLs.filter { Self.key(for: $0) != path }
        NSDocumentController.shared.clearRecentDocuments(nil)
        for item in remaining.reversed() {
            Self.writeBookmark(item)
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
