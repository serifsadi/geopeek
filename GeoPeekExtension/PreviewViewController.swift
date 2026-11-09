//
//  PreviewViewController.swift
//  GeoPeekExtension
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import Cocoa
import Quartz
import WebKit

// MARK: - View controller

class PreviewViewController: NSViewController, QLPreviewingController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!
    private var spinner: NSProgressIndicator!
    /// Base URL of the document most recently passed to `loadHTMLString`.
    /// `nil` allows only `about:blank` (the text fallback, and the initial empty page).
    private var documentBaseURL: URL?
    /// Map page held until the preview view is in a window with a non-zero
    /// frame. `preparePreviewOfFile` returns before Quick Look lays the panel
    /// out; loading then bakes a 0×0 or 1× viewport into the map canvas.
    private var pendingMapHTML: String?
    private var pendingMapBaseURL: URL?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "mapReady")
        config.userContentController.add(self, name: "basemap")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(webView)
        container.addSubview(spinner)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.acceptsMouseMovedEvents = true
        loadMapPreviewIfReady()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadMapPreviewIfReady()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        loadMapPreviewIfReady()
    }

    /// Loads the stashed map page once Auto Layout has given the web view the
    /// panel's frame inside a window, so `devicePixelRatio` and the viewport
    /// match the Retina backing scale instead of the pre-appearance placeholder.
    private func loadMapPreviewIfReady() {
        guard let html = pendingMapHTML else { return }
        guard view.window != nil else { return }
        let frame = webView.bounds
        guard frame.width > 1, frame.height > 1 else { return }
        let baseURL = pendingMapBaseURL
        pendingMapHTML = nil
        pendingMapBaseURL = nil
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Read on a background thread. I/O errors propagate as throws.
        // GeoJSON renders the map; any other bytes render the text fallback.
        // Quick Look does not fall through to the system JSON preview.
        let fileName = url.lastPathComponent
        let preview = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return renderPreview(data: data, fileName: fileName)
        }.value

        let baseURL = Bundle(for: type(of: self)).resourceURL

        await MainActor.run {
            let ucc = self.webView.configuration.userContentController
            ucc.removeAllUserScripts()
            switch preview {
            case .map(let html, let userScript):
                self.documentBaseURL = baseURL
                ucc.addUserScript(WKUserScript(
                    source: userScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
                self.spinner.isHidden = false
                self.spinner.startAnimation(nil)
                self.pendingMapHTML = html
                self.pendingMapBaseURL = baseURL
                self.loadMapPreviewIfReady()
            case .fallback(let html):
                self.pendingMapHTML = nil
                self.pendingMapBaseURL = nil
                self.documentBaseURL = nil
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "basemap" {
            logBasemapStatus(message.body)
            return
        }
        guard message.name == "mapReady" else { return }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
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
