//
//  GeoPeekApp.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import SwiftUI

@main
struct GeoPeekApp: App {
    var body: some Scene {
        WindowGroup(for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
        }
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
