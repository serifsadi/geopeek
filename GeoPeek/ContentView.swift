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
    @Binding var fileURL: URL?
    @Environment(\.openWindow) private var openWindow
    @State private var isDragOver = false

    var body: some View {
        ZStack {
            if let url = fileURL {
                MapView(fileURL: url, onInaccessible: { fileURL = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WelcomeView(isDragOver: $isDragOver, onOpen: {
                    openGeoJSONFile(into: $fileURL)
                }, onPaste: {
                    pasteGeoJSON(into: $fileURL)
                })
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle(windowTitle)
        .focusedSceneValue(\.fileURL, $fileURL)
        .toolbar {
            // Native macOS back button — only visible while a file is open.
            // QL/Preview has no toolbar, so this never appears there.
            if fileURL != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        fileURL = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Close file")
                }
            }
        }
        // The map's web view does not take file drops, so this receives them.
        // The welcome window loads the file here. A map opens it in its own window.
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            guard let provider = providers.first else { return false }
            let openInNewWindow = fileURL != nil
            // NSURL (not URL) conforms to NSItemProviderReading on macOS
            _ = provider.loadObject(ofClass: NSURL.self) { (nsurl, _) in
                guard let url = nsurl as? URL, isGeoJSONFile(url) else { return }
                DispatchQueue.main.async {
                    RecentFiles.shared.note(url)
                    if openInNewWindow {
                        openWindow(value: url)
                    } else {
                        fileURL = url
                    }
                }
            }
            return true
        }
    }

    // MARK: - Helpers

    private var windowTitle: String {
        guard let url = fileURL else { return "GeoPeek" }
        let name = url.lastPathComponent
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return "GeoPeek  —  \(name)  (\(formatted))"
        }
        return "GeoPeek  —  \(name)"
    }

}

func isGeoJSONFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "geojson" || ext == "json"
}

func openGeoJSONFile(into fileURL: Binding<URL?>) {
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
        RecentFiles.shared.note(url)
        fileURL.wrappedValue = url
    }
}

func pasteGeoJSON(into fileURL: Binding<URL?>) {
    guard let string = NSPasteboard.general.string(forType: .string),
          !string.isEmpty else {
        showPasteError("The clipboard is empty or doesn't contain text.")
        return
    }
    guard let data = string.data(using: .utf8) else {
        showPasteError("Could not process clipboard data.")
        return
    }
    // A unique directory keeps two pastes from sharing one window.
    let name = parseGeoJSON(data) != nil ? "Pasted.geojson" : "Pasted.json"
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("GeoPeek-\(UUID().uuidString)", isDirectory: true)
    let tempURL = directory.appendingPathComponent(name)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: tempURL, options: .atomic)
        fileURL.wrappedValue = tempURL
    } catch {
        showPasteError("Could not process clipboard data.")
    }
}

private func showPasteError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Paste Failed"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

// MARK: - Welcome / drop zone

struct WelcomeView: View {
    @Binding var isDragOver: Bool
    let onOpen: () -> Void
    let onPaste: () -> Void
    @Environment(\.openWindow) private var openWindow

    private var recentItems: [URL] { Array(RecentFiles.shared.urls.prefix(8)) }

    var body: some View {
        HStack(spacing: 0) {
            welcomeColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !recentItems.isEmpty {
                Divider()
                recentColumn
            }
        }
        .onAppear { RecentFiles.shared.refresh() }
    }

    private var welcomeColumn: some View {
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

            Spacer().frame(height: 8)

            Button(action: onPaste) {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)

            Spacer().frame(height: 16)

            Text("You can also press **Space** on any `.geojson` file in Finder to preview it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Spacer()
        }
        .padding(40)
    }

    private var recentColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(recentItems, id: \.absoluteString) { url in
                Button {
                    openRecent(url, openWindow: openWindow)
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.trailing, 16)
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

/// The web view's private content view accepts file drops. This overlay is hit
/// only while a file drag is active, refuses the drop, and lets it reach SwiftUI.
private final class FileDropOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              NSPasteboard(name: .drag).types?.contains(.fileURL) == true else { return nil }
        return self
    }

    // Refuse the drop so AppKit offers it to the SwiftUI drop destination.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
}

private final class MapRootView: NSView {
    let webView: WKWebView
    private let dropOverlay = FileDropOverlay(frame: .zero)

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        addSubview(webView)
        addSubview(dropOverlay)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        webView.frame = bounds
        dropOverlay.frame = bounds
        passFileDropsThrough(webView)
    }

    private func passFileDropsThrough(_ view: NSView) {
        if let types = view.registeredDraggedTypes, types.contains(.fileURL) {
            view.registerForDraggedTypes(types.filter { $0 != .fileURL })
        }
        view.subviews.forEach(passFileDropsThrough)
    }
}

struct MapView: NSViewRepresentable {
    let fileURL: URL
    var onInaccessible: () -> Void

    func makeNSView(context: Context) -> MapRootView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Serve maplibre-gl.js/.css from the app bundle via a custom scheme so
        // the WKWebView sandbox can load them (file:// doesn't work with
        // loadHTMLString on macOS without loadFileURL, but a scheme handler does).
        config.setURLSchemeHandler(MapLibreSchemeHandler(), forURLScheme: "geopeek")
        config.userContentController.add(context.coordinator, name: "mapReady")
        config.userContentController.add(context.coordinator, name: "basemap")

        let root = MapRootView(configuration: config)
        root.webView.navigationDelegate = context.coordinator
        root.webView.uiDelegate = context.coordinator
        // Explicit background prevents white flash before the map renders.
        root.webView.wantsLayer = true
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        root.webView.layer?.backgroundColor = CGColor(
            red: isDark ? 0.11 : 0.95,
            green: isDark ? 0.11 : 0.95,
            blue: isDark ? 0.12 : 0.97,
            alpha: 1.0
        )
        return root
    }

    func updateNSView(_ root: MapRootView, context: Context) {
        guard context.coordinator.currentURL != fileURL else { return }
        context.coordinator.currentURL = fileURL
        context.coordinator.load(into: root.webView, url: fileURL, onInaccessible: onInaccessible)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var currentURL: URL?
        var onInaccessible: () -> Void = {}
        /// Base URL of the document most recently passed to `loadHTMLString`.
        /// `nil` allows only `about:blank` (the web view's initial empty page).
        private var documentBaseURL: URL?

        // Base URL for the HTML: relative paths ("maplibre-gl.js") resolve to
        // "geopeek://r/maplibre-gl.js", which our scheme handler intercepts.
        private static let baseURL = URL(string: "geopeek://r/")!

        func load(into wv: WKWebView, url: URL, onInaccessible: @escaping () -> Void) {
            self.onInaccessible = onInaccessible
            let name = url.lastPathComponent
            let candidates = RecentFiles.shared.accessCandidates(for: url)
            Task.detached(priority: .userInitiated) {
                var data: Data?
                for candidate in candidates {
                    if let read = Self.contents(of: candidate) {
                        data = read
                        break
                    }
                }
                await MainActor.run {
                    guard let data else {
                        self.onInaccessible()
                        return
                    }
                    self.documentBaseURL = Coordinator.baseURL
                    let ucc = wv.configuration.userContentController
                    ucc.removeAllUserScripts()
                    switch renderPreview(data: data, fileName: name) {
                    case .map(let html, let userScript):
                        ucc.addUserScript(WKUserScript(
                            source: userScript,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true
                        ))
                        wv.loadHTMLString(html, baseURL: Coordinator.baseURL)
                    case .fallback(let html):
                        wv.loadHTMLString(html, baseURL: Coordinator.baseURL)
                    }
                }
            }
        }

        private nonisolated static func contents(of url: URL) -> Data? {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "basemap" {
                logBasemapStatus(message.body)
                return
            }
            // mapReady — no spinner in the standalone app, nothing to do.
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let decision = decideMapNavigation(
                kind: mapNavigationKind(navigationAction.navigationType),
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                documentBaseURL: documentBaseURL
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .openExternally(let url):
                decisionHandler(.cancel)
                openMapLinkInBrowser(url)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // MapLibre's logo link uses target="_blank", which asks for a new
            // web view instead of navigating this one. Open it outside.
            if let url = navigationAction.request.url,
               case .openExternally(let external) = decideMapNavigation(
                    kind: .linkActivated,
                    url: url,
                    isMainFrame: false,
                    documentBaseURL: documentBaseURL
               ) {
                openMapLinkInBrowser(external)
            }
            return nil
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(fileURL: .constant(nil))
}
