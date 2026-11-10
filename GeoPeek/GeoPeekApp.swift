//
//  GeoPeekApp.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

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

    private init() { refresh() }

    func note(_ url: URL) {
        guard !Self.isTemporary(url) else { return }
        let started = url.startAccessingSecurityScopedResource()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if started { url.stopAccessingSecurityScopedResource() }
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
    }

    func refresh() {
        urls = NSDocumentController.shared.recentDocumentURLs.filter { !Self.isTemporary($0) && Self.exists($0) }
    }

    /// The bookmarked recent URL first. A restored URL can compare equal and still have no bookmark.
    func accessCandidates(for url: URL) -> [URL] {
        let path = url.standardizedFileURL.path
        guard let recent = NSDocumentController.shared.recentDocumentURLs.first(where: {
            $0.standardizedFileURL.path == path
        }) else { return [url] }
        return [recent, url]
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
