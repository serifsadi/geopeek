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

class PreviewViewController: NSViewController, QLPreviewingController, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var spinner: NSProgressIndicator!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "mapReady")

        webView = WKWebView(frame: .zero, configuration: config)
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
                let ucc = self.webView.configuration.userContentController
                ucc.removeAllUserScripts()
                ucc.addUserScript(WKUserScript(
                    source: "window.__GEO__='\(p.base64)';",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
                self.spinner.isHidden = false
                self.spinner.startAnimation(nil)
                self.webView.loadHTMLString(makeMapHTML(meta: p.meta), baseURL: baseURL)
            } else {
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
}
