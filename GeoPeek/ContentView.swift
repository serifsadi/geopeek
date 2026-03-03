//
//  ContentView.swift
//  GeoPeek
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Root view

struct ContentView: View {
    @State private var loadedURL: URL?
    @State private var isDragOver = false

    var body: some View {
        ZStack {
            if let url = loadedURL {
                MapView(fileURL: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WelcomeView(isDragOver: $isDragOver) {
                    openFilePicker()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle(windowTitle)
        .toolbar {
            // Native macOS back button — only visible while a file is open.
            // QL/Preview has no toolbar, so this never appears there.
            if loadedURL != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        loadedURL = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Close file")
                }
            }
        }
        // Accept dropped .geojson / .json files
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            guard let provider = providers.first else { return false }
            // NSURL (not URL) conforms to NSItemProviderReading on macOS
            _ = provider.loadObject(ofClass: NSURL.self) { (nsurl, _) in
                guard let url = nsurl as? URL, isGeoJSON(url) else { return }
                DispatchQueue.main.async { loadedURL = url }
            }
            return true
        }
        // ⌘O
        .onReceive(NotificationCenter.default.publisher(for: .openGeoJSONFile)) { _ in
            openFilePicker()
        }
        // File opened from Finder / QL "Open with GeoPeek"
        .onReceive(NotificationCenter.default.publisher(for: .openFileURLs)) { note in
            if let url = note.object as? URL, isGeoJSON(url) {
                loadedURL = url
            }
        }
    }

    // MARK: - Helpers

    private var windowTitle: String {
        guard let url = loadedURL else { return "GeoPeek" }
        let name = url.lastPathComponent
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return "GeoPeek  —  \(name)  (\(formatted))"
        }
        return "GeoPeek  —  \(name)"
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles           = true
        panel.canChooseDirectories     = false
        panel.allowsMultipleSelection  = false
        panel.allowedContentTypes      = [
            UTType(filenameExtension: "geojson") ?? .json,
            .json
        ]
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            loadedURL = url
        }
    }

    private func isGeoJSON(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "geojson" || ext == "json"
    }
}

// MARK: - Welcome / drop zone

struct WelcomeView: View {
    @Binding var isDragOver: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                Text("GeoPeek")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("GeoJSON Quick Look & Viewer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 32)

            dropZone

            Spacer().frame(height: 20)

            Button(action: onOpen) {
                Label("Open GeoJSON File…", systemImage: "doc.badge.plus")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.976, green: 0.451, blue: 0.086))

            Spacer().frame(height: 16)

            Text("You can also press **Space** on any `.geojson` file in Finder to preview it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropZone: some View {
        let accent = Color(red: 0.976, green: 0.451, blue: 0.086)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isDragOver ? accent : Color.secondary.opacity(0.30),
                style: StrokeStyle(lineWidth: isDragOver ? 2 : 1.5, dash: [6, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDragOver ? accent.opacity(0.07) : Color.clear)
            )
            .frame(width: 260, height: 100)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isDragOver ? accent : .secondary)
                    Text("Drop a GeoJSON file here")
                        .font(.callout)
                        .foregroundStyle(isDragOver ? Color.primary : Color.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDragOver)
    }
}

// MARK: - WKURLSchemeHandler for maplibre assets

/// Serves `maplibre-gl.js` and `maplibre-gl.css` from the app bundle via the
/// custom `geopeek://` scheme, letting `loadHTMLString(_:baseURL:)` resolve
/// relative resource URLs without hitting WKWebView's file:// sandbox limits.
private final class MapLibreSchemeHandler: NSObject, WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let fileName  = requestURL.lastPathComponent          // e.g. "maplibre-gl.js"
        let ext       = (fileName as NSString).pathExtension  // "js" or "css"
        let baseName  = (fileName as NSString).deletingPathExtension  // "maplibre-gl"

        guard !baseName.isEmpty,
              let resourceURL = Bundle.main.url(forResource: baseName,
                                                withExtension: ext),
              let data = try? Data(contentsOf: resourceURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }

        let mime = ext == "js" ? "application/javascript" : "text/css"
        let response = URLResponse(url: requestURL,
                                   mimeType: mime,
                                   expectedContentLength: data.count,
                                   textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - Map NSViewRepresentable

struct MapView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Serve maplibre-gl.js/.css from the app bundle via a custom scheme so
        // the WKWebView sandbox can load them (file:// doesn't work with
        // loadHTMLString on macOS without loadFileURL, but a scheme handler does).
        config.setURLSchemeHandler(MapLibreSchemeHandler(), forURLScheme: "geopeek")
        config.userContentController.add(context.coordinator, name: "mapReady")

        let wv = WKWebView(frame: .zero, configuration: config)
        // Explicit background prevents white flash before the map renders.
        wv.wantsLayer = true
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        wv.layer?.backgroundColor = CGColor(
            red: isDark ? 0.11 : 0.95,
            green: isDark ? 0.11 : 0.95,
            blue: isDark ? 0.12 : 0.97,
            alpha: 1.0
        )
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard context.coordinator.currentURL != fileURL else { return }
        context.coordinator.currentURL = fileURL
        context.coordinator.load(into: wv, url: fileURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var currentURL: URL?

        // Base URL for the HTML: relative paths ("maplibre-gl.js") resolve to
        // "geopeek://r/maplibre-gl.js", which our scheme handler intercepts.
        private static let baseURL = URL(string: "geopeek://r/")!

        func load(into wv: WKWebView, url: URL) {
            Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else {
                    await MainActor.run {
                        wv.loadHTMLString(makeErrorHTML(), baseURL: Coordinator.baseURL)
                    }
                    return
                }
                let b64 = data.base64EncodedString()
                await MainActor.run {
                    guard let meta = parseGeoJSON(data) else {
                        wv.loadHTMLString(makeErrorHTML(), baseURL: Coordinator.baseURL)
                        return
                    }
                    let html = makeMapHTML(meta: meta)
                    let ucc  = wv.configuration.userContentController
                    ucc.removeAllUserScripts()
                    ucc.addUserScript(WKUserScript(
                        source: "window.__GEO__='\(b64)';",
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    ))
                    wv.loadHTMLString(html, baseURL: Coordinator.baseURL)
                }
            }
        }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // mapReady — no spinner in the standalone app, nothing to do.
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
