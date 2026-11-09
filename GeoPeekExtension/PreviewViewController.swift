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
    /// `nil` allows only `about:blank` (parse errors, and the initial empty page).
    private var documentBaseURL: URL?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "mapReady")

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
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Read + parse on a background thread.
        // I/O errors propagate as throws; parse failures show a styled error page.
        struct Parsed { let base64: String; let meta: GeoJSONMeta }

        let result: Parsed? = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)          // I/O failure → throws
            guard let meta = parseGeoJSON(data) else { return nil }
            return Parsed(base64: data.base64EncodedString(), meta: meta)
        }.value

        let baseURL = Bundle(for: type(of: self)).resourceURL

        await MainActor.run {
            if let p = result {
                self.documentBaseURL = baseURL
                let ucc = self.webView.configuration.userContentController
                ucc.removeAllUserScripts()
                ucc.addUserScript(WKUserScript(
                    source: geoJSONInjectionScript(base64: p.base64),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
                self.spinner.isHidden = false
                self.spinner.startAnimation(nil)
                self.webView.loadHTMLString(makeMapHTML(meta: p.meta), baseURL: baseURL)
            } else {
                self.documentBaseURL = nil
                self.spinner.isHidden = true
                self.webView.loadHTMLString(makeErrorHTML(), baseURL: nil)
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
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
