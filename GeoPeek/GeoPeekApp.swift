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
        // The delegate cannot see `openWindow`. Capture it for as long as the
        // scene exists, including after the last window has been closed.
        let _ = appDelegate.install(openWindow: openWindow)

        WindowGroup(id: ViewerScene.id, for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open GeoJSON File…") {
                    postToKeyWindow(.openGeoJSONFile)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Paste GeoJSON") {
                    postToKeyWindow(.pasteGeoJSON)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
    }
}

/// Menu commands carry the key window so only that window acts on them.
private func postToKeyWindow(_ name: Notification.Name) {
    NotificationCenter.default.post(name: name, object: NSApp.keyWindow ?? NSApp.mainWindow)
}

enum ViewerScene {
    static let id = "viewer"
}

enum GeoFileURL {
    /// Same path, stable enough for "is this file already open?".
    /// Does not resolve symlinks, so a sandboxed open keeps its path.
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    static func isGeoJSON(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "geojson" || ext == "json"
    }
}

// MARK: - Which window is showing which file

/// Per-window record of the file on screen. External opens consult this
/// instead of broadcasting to every `ContentView`.
@MainActor
final class OpenWindows {
    static let shared = OpenWindows()

    private struct Slot {
        var url: URL?
        weak var window: NSWindow?
        var adopt: (URL) -> Void
    }

    private var slots: [UUID: Slot] = [:]
    /// True while an empty launch window is taking a file, so a re-entrant
    /// view update cannot clear the URL we just assigned.
    private var adopting = false

    var shouldCloseEmptyLaunchWindow = false

    func update(id: UUID, url: URL?, window: NSWindow?, adopt: @escaping (URL) -> Void) {
        if adopting, url == nil, slots[id]?.url != nil {
            slots[id] = Slot(url: slots[id]?.url, window: window ?? slots[id]?.window, adopt: adopt)
            return
        }
        slots[id] = Slot(url: url, window: window, adopt: adopt)
    }

    func remove(id: UUID) {
        slots[id] = nil
    }

    /// Bring forward the window that already shows this file.
    /// `url` may be the original open URL; slots store the canonical path.
    func focus(_ url: URL) -> Bool {
        let key = GeoFileURL.canonical(url)
        guard let window = slots.values.first(where: { $0.url == key })?.window,
              NSApp.windows.contains(where: { $0 === window }) else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Cold launch opens one empty window. Put the file in it when it is the
    /// only window, so the open does not leave a blank window beside it.
    /// The original URL is kept so a security-scoped open stays readable.
    func adoptIfSoleEmpty(_ url: URL) -> Bool {
        guard slots.count == 1, let (id, slot) = slots.first, slot.url == nil else { return false }
        adopting = true
        defer { adopting = false }
        slots[id]?.url = GeoFileURL.canonical(url)
        slot.adopt(url)
        NSApp.activate()
        slot.window?.makeKeyAndOrderFront(nil)
        return true
    }

    var isEmpty: Bool { slots.isEmpty }

    var containsFile: Bool { slots.values.contains { $0.url != nil } }

    func consumeEmptyLaunchDismissal() -> Bool {
        guard shouldCloseEmptyLaunchWindow else { return false }
        shouldCloseEmptyLaunchWindow = false
        return true
    }
}

// MARK: - App delegate (file opens from Finder / Launch Services)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindow: OpenWindowAction?
    private var queued: [URL] = []
    private var launchComplete = false
    private var hasActivated = false
    private var didRestoreState = false

    func install(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `application(_:open:)` for a document launch is usually earlier,
        // but it can also land just after this returns. Settle on the next turn.
        DispatchQueue.main.async {
            self.launchComplete = true
            self.flush()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async {
            self.hasActivated = true
            // A welcome window created after activation is the user's, not the
            // automatic one from launch.
            DispatchQueue.main.async {
                OpenWindows.shared.shouldCloseEmptyLaunchWindow = false
            }
        }
    }

    func application(_ application: NSApplication, didDecodeRestorableState coder: NSCoder) {
        didRestoreState = true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard GeoFileURL.isGeoJSON(url) else { continue }
            let key = GeoFileURL.canonical(url)
            guard !queued.contains(where: { GeoFileURL.canonical($0) == key }) else { continue }
            // Keep the URL Launch Services handed us. Standardizing it drops
            // the security scope the sandbox uses to read the file.
            queued.append(url)
        }
        flush()
    }

    private func flush() {
        guard launchComplete, let openWindow else { return }
        let files = queued
        queued.removeAll()
        for file in files {
            show(file, openWindow: openWindow)
        }
    }

    private func show(_ url: URL, openWindow: OpenWindowAction) {
        if OpenWindows.shared.focus(url) { return }

        let duringLaunch = !hasActivated && !didRestoreState
        if duringLaunch, OpenWindows.shared.adoptIfSoleEmpty(url) { return }

        let dismissBlankLaunchWindow = duringLaunch && OpenWindows.shared.isEmpty
        NSApp.activate()
        openWindow(id: ViewerScene.id, value: url)
        guard dismissBlankLaunchWindow else { return }
        OpenWindows.shared.shouldCloseEmptyLaunchWindow = true
        NotificationCenter.default.post(name: .suppressAutomaticEmptyWindow, object: nil)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openGeoJSONFile = Notification.Name("dev.serifsadi.GeoPeek.openGeoJSONFile")
    static let pasteGeoJSON = Notification.Name("dev.serifsadi.GeoPeek.pasteGeoJSON")
    /// Posted once when a file open at launch creates a real window, so the
    /// automatic blank window can close.
    static let suppressAutomaticEmptyWindow = Notification.Name("dev.serifsadi.GeoPeek.suppressAutomaticEmptyWindow")
}
