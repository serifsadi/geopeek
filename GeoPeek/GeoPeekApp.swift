//
//  GeoPeekApp.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import SwiftUI

@main
struct GeoPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open GeoJSON File…") {
                    NotificationCenter.default.post(name: .openGeoJSONFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

// MARK: - App delegate (handles file-open events from Finder / QL)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .openFileURLs, object: url)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openGeoJSONFile = Notification.Name("dev.serifsadi.GeoPeek.openGeoJSONFile")
    static let openFileURLs    = Notification.Name("dev.serifsadi.GeoPeek.openFileURLs")
}
