//
//  GeoPeekApp.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import SwiftUI

let viewerWindowID = "viewer"

@main
struct GeoPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = appDelegate.install(openWindow: openWindow)
        WindowGroup(id: viewerWindowID, for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
        }
        .commands { ViewerCommands() }
    }
}

struct ViewerCommands: Commands {
    @FocusedValue(\.windowFile) private var windowFile

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open GeoJSON File…") { windowFile?.open() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(windowFile == nil)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Paste GeoJSON") { windowFile?.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(windowFile == nil)
        }
    }
}

// Identity, not URL equality: two welcome windows both have a nil file.
final class WindowFile: Equatable {
    var fileURL: Binding<URL?>
    var open: () -> Void = {}
    var paste: () -> Void = {}
    init(_ fileURL: Binding<URL?>) { self.fileURL = fileURL }
    nonisolated static func == (lhs: WindowFile, rhs: WindowFile) -> Bool { lhs === rhs }
}

extension FocusedValues {
    var windowFile: WindowFile? {
        get { self[WindowFileKey.self] }
        set { self[WindowFileKey.self] = newValue }
    }
    private struct WindowFileKey: FocusedValueKey { typealias Value = WindowFile }
}

// Which welcome window, if it is the only one, should adopt an opened file.
@MainActor
enum WelcomeWindow {
    static var pending: URL?
    static var hasActivated = false
    private static var viewers: [WindowFile] = []
    static func register(_ file: WindowFile) {
        if !viewers.contains(where: { $0 === file }) { viewers.append(file) }
    }
    static func unregister(_ file: WindowFile) { viewers.removeAll { $0 === file } }
    static var isEmpty: Bool { viewers.isEmpty }
    static var soleEmpty: WindowFile? {
        viewers.count == 1 && viewers[0].fileURL.wrappedValue == nil ? viewers[0] : nil
    }
    static func takePending() -> URL? { defer { pending = nil }; return pending }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindow: OpenWindowAction?
    private var queued: [URL] = []
    private var isFlushing = false

    func install(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        WelcomeWindow.hasActivated = true
        guard let url = WelcomeWindow.pending, !WelcomeWindow.isEmpty, WelcomeWindow.soleEmpty == nil else { return }
        WelcomeWindow.pending = nil
        queued.insert(url, at: 0)
        flush()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        queued.append(contentsOf: urls.filter { ["geojson", "json"].contains($0.pathExtension.lowercased()) })
        flush()
    }

    private func flush() {
        guard !isFlushing, let openWindow, !queued.isEmpty else { return }
        isFlushing = true
        while !queued.isEmpty {
            let url = queued.removeFirst()
            if let empty = WelcomeWindow.soleEmpty {
                empty.fileURL.wrappedValue = url
            } else if WelcomeWindow.isEmpty, !WelcomeWindow.hasActivated, WelcomeWindow.pending == nil {
                WelcomeWindow.pending = url
            } else if WelcomeWindow.pending != url {
                openWindow(id: viewerWindowID, value: url)
            }
        }
        isFlushing = false
        NSApp.activate()
    }
}
