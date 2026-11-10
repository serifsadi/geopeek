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
    @FocusedValue(\.openGeoJSON) private var openGeoJSON
    @FocusedValue(\.pasteGeoJSON) private var pasteGeoJSON

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open GeoJSON File…") { openGeoJSON?() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(openGeoJSON == nil)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Paste GeoJSON") { pasteGeoJSON?() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(pasteGeoJSON == nil)
        }
    }
}

extension FocusedValues {
    @Entry var openGeoJSON: (() -> Void)?
    @Entry var pasteGeoJSON: (() -> Void)?
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
        urls.forEach { openWindow(value: $0) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter {
            ["geojson", "json"].contains($0.pathExtension.lowercased())
        }
        guard let openWindow else {
            queued.append(contentsOf: files)
            return
        }
        files.forEach { openWindow(value: $0) }
    }
}
