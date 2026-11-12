//
//  GeoRenderer.swift
//  Shared — compiled into both GeoPeek and GeoPeekExtension
//
//  Single source of truth for GeoJSON parsing, the map page, and the
//  plain-JSON / raw-text fallback. Changes here apply to the QL preview
//  extension and the standalone app simultaneously.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(macOS)
import os

// The map page posts `{ok, url, message}` once per basemap load. Subsystem is
// the host bundle id (`dev.serifsadi.GeoPeek` in the app,
// `dev.serifsadi.GeoPeek.GeoPeekExtension` in Quick Look).
private let basemapLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.serifsadi.GeoPeek",
    category: "basemap"
)
#endif

func logBasemapStatus(_ body: Any) {
    #if os(macOS)
    let info = body as? [String: Any]
    let url = info?["url"] as? String ?? ""
    let message = info?["message"] as? String ?? ""
    let ok = (info?["ok"] as? Bool) ?? (info?["ok"] as? NSNumber)?.boolValue ?? false
    if info == nil {
        basemapLog.error("basemap unavailable error=\(String(describing: body), privacy: .public)")
    } else if ok {
        basemapLog.info("basemap style loaded url=\(url, privacy: .public)")
    } else {
        basemapLog.error("basemap unavailable url=\(url, privacy: .public) error=\(message, privacy: .public)")
    }
    #else
    _ = body
    #endif
}

// MARK: - Data model

struct GeoBounds {
    let minLng: Double
    let maxLng: Double
    let minLat: Double
    let maxLat: Double
}

struct GeoJSONMeta {
    var featureCount: Int = 0
    var vertexCount:  Int = 0
    var geometryTypes: [String] = []
    var bounds: GeoBounds?
}

// MARK: - Parsing

/// RFC 7946 §1.4. A geometry `type` is file-controlled text; only these seven
/// strings are ever copied into the page. Anything else is ignored.
private let _geometryTypes: Set<String> = [
    "Point", "MultiPoint",
    "LineString", "MultiLineString",
    "Polygon", "MultiPolygon",
    "GeometryCollection"
]

private let _validGeoJSONTypes: Set<String> = _geometryTypes.union([
    "FeatureCollection", "Feature"
])

/// Parses `data` as GeoJSON. Returns nil unless the root value is a JSON
/// object whose `type` is `Feature`, `FeatureCollection`, or one of the seven
/// RFC 7946 geometry types. The filename is not consulted — `.json` and
/// `.geojson` take this same path. Thread-safe; uses only local state.
func parseGeoJSON(_ data: Data) -> GeoJSONMeta? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return geoJSONMeta(from: root)
}

/// `root` is an already-parsed JSON object. Nil unless `type` is GeoJSON.
private func geoJSONMeta(from root: [String: Any]) -> GeoJSONMeta? {
    guard let type = root["type"] as? String,
          _validGeoJSONTypes.contains(type) else { return nil }

    var meta      = GeoJSONMeta()
    var minLng    = Double.infinity,  maxLng = -Double.infinity
    var minLat    = Double.infinity,  maxLat = -Double.infinity
    var geomTypes = Set<String>()

    func walkCoords(_ coords: Any) {
        guard let arr = coords as? [Any] else { return }
        if !arr.isEmpty, !(arr[0] is [Any]), arr.count >= 2,
           let lng = (arr[0] as? NSNumber)?.doubleValue,
           let lat = (arr[1] as? NSNumber)?.doubleValue {
            meta.vertexCount += 1
            if lng < minLng { minLng = lng }; if lng > maxLng { maxLng = lng }
            if lat < minLat { minLat = lat }; if lat > maxLat { maxLat = lat }
        } else {
            arr.forEach { walkCoords($0) }
        }
    }

    func walkGeometry(_ geom: [String: Any]) {
        guard let gType = geom["type"] as? String,
              _geometryTypes.contains(gType) else { return }
        if gType == "GeometryCollection" {
            (geom["geometries"] as? [[String: Any]])?.forEach { walkGeometry($0) }
        } else {
            geomTypes.insert(gType)
            if let coords = geom["coordinates"] { walkCoords(coords) }
        }
    }

    switch type {
    case "FeatureCollection":
        let features = (root["features"] as? [[String: Any]]) ?? []
        meta.featureCount = features.count
        features.forEach { if let g = $0["geometry"] as? [String: Any] { walkGeometry(g) } }
    case "Feature":
        meta.featureCount = 1
        if let g = root["geometry"] as? [String: Any] { walkGeometry(g) }
    default:
        meta.featureCount = 1
        walkGeometry(root)
    }

    meta.geometryTypes = geomTypes.sorted()
    if minLng.isFinite { meta.bounds = GeoBounds(minLng: minLng, maxLng: maxLng,
                                                 minLat: minLat, maxLat: maxLat) }
    return meta
}

// MARK: - Embedding file data in the page

/// JSON text safe to place inside `<script>` or a `WKUserScript`.
/// `JSONSerialization` quotes and escapes the value; `<`, `>`, `&`, and the
/// JS line separators U+2028/U+2029 are then rewritten as `\uXXXX` so the
/// HTML parser cannot close the script element and the JS parser cannot
/// treat a string as two lines. The decoded value is unchanged.
func scriptSafeJSONObject(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
        return #"{"bounds":null,"featureCount":0,"geometryTypes":[],"vertexCount":0}"#
    }
    return escapeForInlineScript(json)
}

/// A JSON string literal, including the surrounding quotes.
func scriptSafeJSONString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let json = String(data: data, encoding: .utf8),
          json.first == "[", json.last == "]" else {
        return "\"\""
    }
    // JSONSerialization emits `[` + literal + `]` with no extra whitespace.
    let literal = String(json.dropFirst().dropLast())
    return escapeForInlineScript(literal)
}

/// Statement injected at document start. The file bytes stay inside one
/// JSON string; they are not interpolated into the HTML template.
func geoJSONInjectionScript(base64: String) -> String {
    "window.__GEO__=\(scriptSafeJSONString(base64));"
}

private func escapeForInlineScript(_ json: String) -> String {
    json
        .replacingOccurrences(of: "&", with: "\\u0026")
        .replacingOccurrences(of: "<", with: "\\u003c")
        .replacingOccurrences(of: ">", with: "\\u003e")
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

/// HTML-text counterpart of `escapeForInlineScript`. Fallback pages put file
/// text in element bodies, so the same characters (plus quotes) are written
/// as entities. `&` is replaced first. The decoded glyphs are unchanged.
private func escapeHTMLText(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for ch in text {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        case "\u{2028}": out += "&#x2028;"
        case "\u{2029}": out += "&#x2029;"
        default: out.append(ch)
        }
    }
    return out
}

private func mapMetaObject(_ meta: GeoJSONMeta) -> [String: Any] {
    let bounds: Any
    if let b = meta.bounds {
        bounds = [[b.minLng, b.minLat], [b.maxLng, b.maxLat]]
    } else {
        bounds = NSNull()
    }
    return [
        "featureCount": meta.featureCount,
        "vertexCount": meta.vertexCount,
        "geometryTypes": meta.geometryTypes,
        "bounds": bounds
    ]
}

// MARK: - Navigation policy

/// How the web view is trying to navigate. Mapped from `WKNavigationType`
/// by the app and the Quick Look extension.
enum MapNavigationKind: Equatable {
    /// `loadHTMLString` (`.other`).
    case documentLoad
    /// A clicked `<a href>` (`.linkActivated`), including `target="_blank"`.
    case linkActivated
    /// Form submits, back/forward, reloads, and anything added later.
    case other
}

enum MapNavigationDecision: Equatable {
    case allow
    /// Cancel the web view navigation and open this URL in the system browser.
    case openExternally(URL)
    case cancel
}

/// Allows only the document produced by `loadHTMLString`, and sends http(s)
/// link clicks (map attribution, MapLibre logo) to the system browser.
///
/// `documentBaseURL` is the base URL passed to `loadHTMLString`. `nil` means
/// that call used `about:blank` (the error page, and the web view's initial
/// empty document). WebKit's request URL for `loadData` is that base URL.
func decideMapNavigation(kind: MapNavigationKind,
                         url: URL?,
                         isMainFrame: Bool,
                         documentBaseURL: URL?) -> MapNavigationDecision {
    switch kind {
    case .linkActivated:
        if let url, isBrowserURL(url) {
            return .openExternally(url)
        }
        return .cancel
    case .documentLoad:
        guard isMainFrame, let url else { return .cancel }
        let expected = documentBaseURL ?? URL(string: "about:blank")!
        guard let actualKey = canonicalDocumentURL(url),
              let expectedKey = canonicalDocumentURL(expected),
              actualKey == expectedKey else { return .cancel }
        return .allow
    case .other:
        return .cancel
    }
}

private func isBrowserURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty else { return false }
    return true
}

/// Scheme + host + path, with an empty path and `/` treated as the same
/// document. Query strings and fragments never match, so they cannot widen
/// the allowed document. Returns nil for `about:` URLs other than `about:blank`.
private func canonicalDocumentURL(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
    if url.query != nil || url.fragment != nil { return nil }
    if scheme == "about" {
        let body = url.absoluteString.split(separator: ":", maxSplits: 1).last
            .map(String.init)?.lowercased() ?? ""
        return body == "blank" ? "about:blank" : nil
    }
    let host = (url.host ?? "").lowercased()
    let path = url.path.isEmpty ? "/" : url.path
    let trimmed = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
    return "\(scheme)://\(host)\(trimmed)"
}

#if canImport(WebKit)
func mapNavigationKind(_ type: WKNavigationType) -> MapNavigationKind {
    switch type {
    case .linkActivated:
        return .linkActivated
    case .other:
        return .documentLoad
    case .formSubmitted, .backForward, .reload, .formResubmitted:
        return .other
    @unknown default:
        return .other
    }
}
#endif

#if canImport(WebKit) && canImport(AppKit)
/// Opens an attribution (or other http(s)) link outside the map web view.
@MainActor
func openMapLinkInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
}
#endif

// MARK: - HTML generation

/// Static page for a file that could not be read. Text that parsed, including
/// JSON that is not GeoJSON, uses `makeJSONFallbackHTML` instead.
func makeErrorHTML(format: String = "GeoJSON") -> String {
    let name = escapeHTMLText(format)
    return statusCardHTML(
        title: "Not Valid \(name)",
        message: "This file doesn't contain recognisable \(name) data and cannot be previewed."
    )
}

/// Same card as the Not Valid page. The file parsed; GeoPeek has nothing to draw.
func makeNothingToPreviewHTML(kind: GeoImportKind) -> String {
    let title = NSLocalizedString(
        "Nothing to Preview",
        comment: "Heading on the page shown when a KML or KMZ file only contains network links or image overlays"
    )
    switch kind {
    case .kml:
        return statusCardHTML(
            title: title,
            message: NSLocalizedString(
                "This KML file only contains network links or image overlays, which GeoPeek doesn't show yet.",
                comment: "Body text on the page shown when a KML file only contains network links or image overlays"
            )
        )
    case .kmz:
        return statusCardHTML(
            title: title,
            message: NSLocalizedString(
                "This KMZ file only contains network links or image overlays, which GeoPeek doesn't show yet.",
                comment: "Body text on the page shown when a KMZ file only contains network links or image overlays"
            )
        )
    case .gpx:
        return makeErrorHTML(format: kind.displayName)
    }
}

private func statusCardHTML(title: String, message: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        :root {
          --bg:     #f2f2f7;
          --label:  rgba(0,0,0,0.847);
          --label2: rgba(60,60,67,0.60);
          --icon-c: rgba(142,142,147,0.80);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg:     #1c1c1e;
            --label:  rgba(255,255,255,0.847);
            --label2: rgba(235,235,245,0.60);
            --icon-c: rgba(174,174,178,0.70);
          }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body {
          width: 100%; height: 100%;
          display: flex; align-items: center; justify-content: center;
          background: var(--bg);
          font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        .card { text-align: center; max-width: 220px; }
        .icon { color: var(--icon-c); margin-bottom: 12px; line-height: 0; }
        h1 {
          font-size: 13px; font-weight: 600;
          color: var(--label); letter-spacing: -0.008em; margin-bottom: 5px;
        }
        .sub { font-size: 11px; line-height: 1.55; color: var(--label2); }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">
          <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor"
               stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
            <line x1="12" y1="9" x2="12" y2="13"/>
            <circle cx="12" cy="17" r="0.5" fill="currentColor" stroke="none"/>
          </svg>
        </div>
        <h1>\(title)</h1>
        <p class="sub">\(message)</p>
      </div>
    </body>
    </html>
    """
}

// MARK: - JSON / raw-text fallback

/// Most file text a fallback page will embed. Larger files keep a prefix.
let jsonFallbackMaxBytes = 5 * 1024 * 1024

enum RenderedPreview {
    /// Map page, plus the `window.__GEO__` script injected at document start.
    case map(html: String, userScript: String)
    /// Read-only JSON or raw text. No script, no file-controlled URLs.
    case fallback(html: String)
    /// The Not Valid page. An empty or malformed file did not open.
    case invalid(html: String)
    /// Valid KML or KMZ that only has network links or image overlays.
    case nothingToPreview(html: String)
}

/// Map when `data` is GeoJSON; otherwise the read-only fallback. The decision
/// is the root `type`, never the filename. The file is parsed once.
func renderPreview(data: Data,
                   fileName: String,
                   maxFallbackBytes: Int = jsonFallbackMaxBytes) -> RenderedPreview {
    if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        if let root = value as? [String: Any], let meta = geoJSONMeta(from: root) {
            return .map(
                html: makeMapHTML(meta: meta),
                userScript: geoJSONInjectionScript(base64: data.base64EncodedString())
            )
        }
        return .fallback(html: jsonFallbackHTML(
            fileName: fileName, data: data, maxBytes: maxFallbackBytes, parsed: value))
    }
    return .fallback(html: jsonFallbackHTML(
        fileName: fileName, data: data, maxBytes: maxFallbackBytes, parsed: nil))
}

/// GeoJSON and JSON keep `renderPreview`. KML, KMZ, and GPX are converted
/// first. An empty or malformed import uses the same not-valid page, named
/// for that format. A KML or KMZ file that only has network links or image
/// overlays uses the nothing-to-preview page.
func renderFilePreview(data: Data,
                       fileName: String,
                       maxFallbackBytes: Int = jsonFallbackMaxBytes) -> RenderedPreview {
    if let kind = GeoImportKind(fileName: fileName) {
        switch importGeoData(data, kind: kind) {
        case .geoJSON(let geoJSON):
            return renderPreview(data: geoJSON, fileName: fileName, maxFallbackBytes: maxFallbackBytes)
        case .nothingToPreview:
            return .nothingToPreview(html: makeNothingToPreviewHTML(kind: kind))
        case .invalid:
            return .invalid(html: makeErrorHTML(format: kind.displayName))
        }
    }
    return renderPreview(data: data, fileName: fileName, maxFallbackBytes: maxFallbackBytes)
}

/// Read-only page for a file that is not GeoJSON.
///
/// Valid JSON under `maxBytes` is pretty-printed and lightly colored. Anything
/// else is the raw text, with a parse-error line when the bytes are not JSON.
/// Above `maxBytes` the page shows an escaped prefix and a truncation note
/// instead of pretty-printing. Every copied character goes through
/// `escapeHTMLText`; the page has no script and no file-controlled attributes.
func makeJSONFallbackHTML(fileName: String,
                          data: Data,
                          maxBytes: Int = jsonFallbackMaxBytes) -> String {
    let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return jsonFallbackHTML(fileName: fileName, data: data, maxBytes: maxBytes, parsed: parsed)
}

private func jsonFallbackHTML(fileName: String,
                              data: Data,
                              maxBytes: Int,
                              parsed: Any?) -> String {
    let cap = max(0, maxBytes)
    let displayName = fileName.isEmpty ? "Untitled" : fileName
    let oversize = data.count > cap

    let body: String
    let note: String?
    let parseError: Bool

    if oversize {
        let prefix = utf8Prefix(data, maxBytes: cap)
        body = escapeHTMLText(String(decoding: prefix, as: UTF8.self))
        note = "Showing the first \(formatByteCount(prefix.count)) of \(formatByteCount(data.count))."
        parseError = parsed == nil
    } else if let value = parsed, let source = prettyJSONText(value, original: data) {
        let capped = prefixUTF8(source, maxBytes: cap)
        body = highlightJSON(capped.text)
        note = capped.truncated
            ? "Showing the first \(formatByteCount(capped.bytes)) of the pretty-printed JSON."
            : nil
        parseError = false
    } else {
        body = escapeHTMLText(String(decoding: data, as: UTF8.self))
        note = nil
        parseError = true
    }

    return jsonFallbackDocument(
        fileName: escapeHTMLText(displayName),
        byteCount: escapeHTMLText(formatByteCount(data.count)),
        parseError: parseError,
        note: note.map(escapeHTMLText),
        body: body
    )
}

private func prettyJSONText(_ value: Any, original: Data) -> String? {
    if JSONSerialization.isValidJSONObject(value) {
        // Re-indent the original text so key order and token spelling survive.
        // JSONSerialization's object graph does not promise either.
        if var text = String(data: original, encoding: .utf8) {
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
            return prettyPrintedJSON(text)
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
    }
    // Top-level string, number, bool, or null. The source is already JSON.
    if var text = String(data: original, encoding: .utf8) {
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(decoding: original, as: UTF8.self)
}

/// Two-space pretty JSON. Tokens are copied verbatim; only insignificant
/// whitespace is replaced. The input is JSON that already parsed.
private func prettyPrintedJSON(_ json: String) -> String {
    var out = ""
    out.reserveCapacity(json.count + json.count / 8)
    var i = json.startIndex
    var indent = 0

    func skipWhitespace() {
        while i < json.endIndex {
            switch json[i] {
            case " ", "\n", "\r", "\t":
                i = json.index(after: i)
            default:
                return
            }
        }
    }

    func newline() {
        out.append("\n")
        if indent > 0 {
            out.append(String(repeating: " ", count: indent * 2))
        }
    }

    skipWhitespace()
    while i < json.endIndex {
        let c = json[i]
        if c == " " || c == "\n" || c == "\r" || c == "\t" {
            skipWhitespace()
            continue
        }
        if c == "{" || c == "[" {
            out.append(c)
            i = json.index(after: i)
            indent += 1
            skipWhitespace()
            let close: Character = c == "{" ? "}" : "]"
            if i < json.endIndex && json[i] == close {
                out.append(close)
                i = json.index(after: i)
                indent -= 1
            } else {
                newline()
            }
            continue
        }
        if c == "}" || c == "]" {
            indent = max(0, indent - 1)
            newline()
            out.append(c)
            i = json.index(after: i)
            continue
        }
        if c == "," {
            out.append(",")
            i = json.index(after: i)
            newline()
            continue
        }
        if c == ":" {
            out.append(": ")
            i = json.index(after: i)
            continue
        }
        if c == "\"" {
            let end = endOfJSONString(json, from: i)
            out.append(contentsOf: json[i..<end])
            i = end
            continue
        }
        let start = i
        while i < json.endIndex {
            switch json[i] {
            case " ", "\n", "\r", "\t", "{", "}", "[", "]", ",", ":", "\"":
                break
            default:
                i = json.index(after: i)
                continue
            }
            break
        }
        if i == start {
            out.append(c)
            i = json.index(after: i)
        } else {
            out.append(contentsOf: json[start..<i])
        }
    }
    return out
}

private struct JSONFrame {
    var object: Bool
    var slot: JSONSlot
}

private enum JSONSlot {
    case key, colon, value, comma
}

/// Wraps keys, strings, numbers, and literals in spans. Punctuation stays
/// plain text. A truncated or invalid slice cannot leave a span open: each
/// token's tags are emitted together, and a cut string runs to the end.
private func highlightJSON(_ json: String) -> String {
    var html = ""
    html.reserveCapacity(json.utf8.count + json.utf8.count / 2 + 64)
    var i = json.startIndex
    var stack: [JSONFrame] = []

    func emit(_ text: String, cls: String?) {
        let escaped = escapeHTMLText(text)
        if let cls {
            html += "<span class=\""
            html += cls
            html += "\">"
            html += escaped
            html += "</span>"
        } else {
            html += escaped
        }
    }

    func finishValue() {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].slot = .comma
    }

    while i < json.endIndex {
        let c = json[i]
        if c == " " || c == "\n" || c == "\r" || c == "\t" {
            let start = i
            repeat { i = json.index(after: i) }
            while i < json.endIndex &&
                (json[i] == " " || json[i] == "\n" || json[i] == "\r" || json[i] == "\t")
            emit(String(json[start..<i]), cls: nil)
            continue
        }
        if c == "\"" {
            let end = endOfJSONString(json, from: i)
            let isKey = stack.last.map { $0.object && $0.slot == .key } ?? false
            if isKey {
                stack[stack.count - 1].slot = .colon
            } else {
                finishValue()
            }
            emit(String(json[i..<end]), cls: isKey ? "k" : "s")
            i = end
            continue
        }
        if c == "{" || c == "[" {
            emit(String(c), cls: nil)
            stack.append(JSONFrame(object: c == "{", slot: c == "{" ? .key : .value))
            i = json.index(after: i)
            continue
        }
        if c == "}" || c == "]" {
            emit(String(c), cls: nil)
            if !stack.isEmpty { stack.removeLast() }
            finishValue()
            i = json.index(after: i)
            continue
        }
        if c == ":" {
            emit(":", cls: nil)
            if let top = stack.last, top.object, top.slot == .colon {
                stack[stack.count - 1].slot = .value
            }
            i = json.index(after: i)
            continue
        }
        if c == "," {
            emit(",", cls: nil)
            if let top = stack.last, top.slot == .comma {
                stack[stack.count - 1].slot = top.object ? .key : .value
            }
            i = json.index(after: i)
            continue
        }
        if c == "-" || (c >= "0" && c <= "9") {
            var j = json.index(after: i)
            while j < json.endIndex {
                let d = json[j]
                if (d >= "0" && d <= "9") || d == "." || d == "e" || d == "E" || d == "+" || d == "-" {
                    j = json.index(after: j)
                } else {
                    break
                }
            }
            emit(String(json[i..<j]), cls: "n")
            finishValue()
            i = j
            continue
        }
        if let end = matchJSONLiteral(json, from: i) {
            emit(String(json[i..<end]), cls: "l")
            finishValue()
            i = end
            continue
        }
        emit(String(c), cls: nil)
        i = json.index(after: i)
    }
    return html
}

private func endOfJSONString(_ json: String, from i: String.Index) -> String.Index {
    var j = json.index(after: i)
    while j < json.endIndex {
        let c = json[j]
        j = json.index(after: j)
        if c == "\\" {
            if j < json.endIndex { j = json.index(after: j) }
            continue
        }
        if c == "\"" { return j }
    }
    return json.endIndex
}

private func matchJSONLiteral(_ json: String, from i: String.Index) -> String.Index? {
    for word in ["true", "false", "null"] {
        guard json[i...].hasPrefix(word) else { continue }
        let end = json.index(i, offsetBy: word.count)
        if end < json.endIndex {
            let next = json[end]
            if next.isLetter || next.isNumber || next == "_" { return nil }
        }
        return end
    }
    return nil
}

private func prefixUTF8(_ text: String, maxBytes: Int) -> (text: String, bytes: Int, truncated: Bool) {
    let data = Data(text.utf8)
    if data.count <= maxBytes {
        return (text, data.count, false)
    }
    let prefix = utf8Prefix(data, maxBytes: maxBytes)
    return (String(decoding: prefix, as: UTF8.self), prefix.count, true)
}

/// Longest prefix of `data` that is at most `maxBytes` and does not split a
/// UTF-8 sequence. The cut looks at the first excluded byte: a continuation
/// means the character started earlier and is dropped whole.
private func utf8Prefix(_ data: Data, maxBytes: Int) -> Data {
    guard maxBytes > 0, !data.isEmpty else { return Data() }
    if data.count <= maxBytes { return data }
    var i = maxBytes
    while i > 0 && (data[i] & 0b1100_0000) == 0b1000_0000 {
        i -= 1
    }
    return Data(data.prefix(i))
}

func formatByteCount(_ bytes: Int) -> String {
    let n = max(0, bytes)
    if n < 1024 {
        return n == 1 ? "1 byte" : "\(n) bytes"
    }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(n)
    var unit = 0
    while value >= 1024 && unit < units.count {
        value /= 1024
        unit += 1
    }
    let tenths = Int((value * 10).rounded())
    var whole = tenths / 10
    let frac = abs(tenths % 10)
    if whole >= 1024 && unit < units.count {
        whole = 1
        unit += 1
    }
    let label = units[unit - 1]
    if frac == 0 {
        return "\(whole) \(label)"
    }
    return "\(whole).\(frac) \(label)"
}

private func jsonFallbackDocument(fileName: String,
                                  byteCount: String,
                                  parseError: Bool,
                                  note: String?,
                                  body: String) -> String {
    let status = parseError ? "\n    <p class=\"status\">Not valid JSON.</p>" : ""
    let noteHTML = note.map { "\n    <p class=\"note\">\($0)</p>" } ?? ""
    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        :root {
          color-scheme: light dark;
          --bg:     #f2f2f7;
          --header: rgba(255,255,255,0.92);
          --label:  rgba(0,0,0,0.847);
          --label2: rgba(60,60,67,0.60);
          --sep:    rgba(60,60,67,0.29);
          --key:    #9a3412;
          --str:    #3f6212;
          --num:    #1e40af;
          --lit:    #6d28d9;
          --warn:   #9a3412;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg:     #1c1c1e;
            --header: rgba(28,28,30,0.94);
            --label:  rgba(255,255,255,0.847);
            --label2: rgba(235,235,245,0.60);
            --sep:    rgba(84,84,88,0.65);
            --key:    #fdba74;
            --str:    #d9f99d;
            --num:    #93c5fd;
            --lit:    #d8b4fe;
            --warn:   #fdba74;
          }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { height: 100%; }
        body {
          overflow: auto;
          background: var(--bg);
          color: var(--label);
          font: 12px/1.5 ui-monospace, 'SF Mono', Menlo, monospace;
          -webkit-font-smoothing: antialiased;
        }
        header {
          position: sticky; top: 0; z-index: 1;
          padding: 10px 14px;
          background: var(--header);
          border-bottom: 0.5px solid var(--sep);
          backdrop-filter: blur(16px);
          -webkit-backdrop-filter: blur(16px);
        }
        .title {
          display: flex; align-items: baseline; justify-content: space-between; gap: 16px;
        }
        h1 {
          min-width: 0;
          font: 600 13px/1.3 -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          letter-spacing: -0.01em;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }
        .size {
          flex: none;
          font: 12px/1.3 -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          color: var(--label2);
        }
        .status, .note {
          margin-top: 4px;
          font: 12px/1.4 -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
        }
        .status { color: var(--warn); }
        .note { color: var(--label2); }
        pre {
          padding: 12px 14px 28px;
          white-space: pre;
          tab-size: 2;
        }
        .k { color: var(--key); }
        .s { color: var(--str); }
        .n { color: var(--num); }
        .l { color: var(--lit); }
      </style>
    </head>
    <body>
      <header>
        <div class="title">
          <h1>\(fileName)</h1>
          <p class="size">\(byteCount)</p>
        </div>\(status)\(noteHTML)
      </header>
      <pre>\(body)</pre>
    </body>
    </html>
    """
}

/// Full map preview page.  The caller injects `window.__GEO__` (base64-encoded
/// GeoJSON) via `WKUserScript` at `.atDocumentStart`, then loads this HTML:
///
/// - **QL extension**: `loadHTMLString(html, baseURL: extensionBundle.resourceURL)`
///   — the extension sandbox allows direct `file://` access to its own bundle.
/// - **Standalone app**: `loadHTMLString(html, baseURL: URL(string:"geopeek://r/"))`
///   — a registered `WKURLSchemeHandler` ("geopeek") serves `maplibre-gl.js/.css`
///   from the app bundle, bypassing WKWebView's `file://` sandbox restrictions.
func makeMapHTML(meta: GeoJSONMeta) -> String {
    // Counts, bounds, and geometry type names cross into JS as one JSON
    // value. No file-derived string is interpolated into the template.
    let metaJSON = scriptSafeJSONObject(mapMetaObject(meta))

    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="stylesheet" href="maplibre-gl.css"/>
      <style>
        /* ── Apple Design System tokens ──────────────────────────────── */
        :root {
          --bg:           #1c1c1e;
          --label:        rgba(255,255,255,0.847);
          --label2:       rgba(235,235,245,0.60);
          --label3:       rgba(235,235,245,0.30);
          --sep:          rgba(84,84,88,0.65);
          --panel-bg:     rgba(44,44,46,0.82);
          --panel-border: rgba(255,255,255,0.095);
          --panel-shadow: 0 2px 12px rgba(0,0,0,0.45), 0 0 0 0.5px rgba(255,255,255,0.06);
          --popup-bg:     #2c2c2e;
          --popup-tip:    #2c2c2e;
          --popup-shadow: 0 6px 24px rgba(0,0,0,0.55);
          --close-btn:    rgba(255,255,255,0.35);
          --close-hover:  rgba(255,255,255,0.75);
          --icon-filter:  invert(1) opacity(0.7);
          --accent:       #f97316;
        }
        @media (prefers-color-scheme: light) {
          :root {
            --bg:           #f2f2f7;
            --label:        rgba(0,0,0,0.847);
            --label2:       rgba(60,60,67,0.60);
            --label3:       rgba(60,60,67,0.30);
            --sep:          rgba(60,60,67,0.29);
            --panel-bg:     rgba(255,255,255,0.80);
            --panel-border: rgba(0,0,0,0.07);
            --panel-shadow: 0 2px 8px rgba(0,0,0,0.10), 0 0 0 0.5px rgba(0,0,0,0.06);
            --popup-bg:     #ffffff;
            --popup-tip:    #ffffff;
            --popup-shadow: 0 4px 20px rgba(0,0,0,0.14);
            --close-btn:    rgba(0,0,0,0.30);
            --close-hover:  rgba(0,0,0,0.70);
            --icon-filter:  opacity(0.55);
            --accent:       #c2410c;
          }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body, #map { width: 100%; height: 100%; }
        body { background: var(--bg); -webkit-font-smoothing: antialiased; }

        .panel {
          position: absolute; z-index: 100;
          border-radius: 10px;
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          box-shadow: var(--panel-shadow);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
          color: var(--label);
          pointer-events: none;
        }

        #stats {
          top: 10px; left: 10px;
          padding: 6px 10px 7px;
          font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          font-size: 12px; line-height: 1;
        }
        .stats-count { font-weight: 600; font-size: 12px; color: var(--label); letter-spacing: -0.01em; }
        .stats-types { margin-top: 3px; font-size: 11px; color: var(--label2); }
        .stats-vertices { margin-top: 2px; font-size: 10.5px; color: var(--label3); }

        #basemap-notice {
          right: 10px; bottom: 44px;
          padding: 6px 10px 7px;
          font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          font-size: 12px; font-weight: 600; line-height: 1;
          letter-spacing: -0.01em;
          white-space: nowrap;
        }

        #coords {
          bottom: 10px; left: 10px;
          padding: 6px 10px 7px;
          font: 12px/1 ui-monospace, 'SF Mono', 'Menlo', monospace;
          color: var(--label2); letter-spacing: 0.01em;
          border-radius: 8px;
          white-space: nowrap;
          visibility: hidden;
        }

        .maplibregl-popup-content {
          background: var(--popup-bg) !important;
          border-radius: 10px !important; padding: 0 !important;
          overflow: hidden; min-width: 168px;
          box-shadow: var(--popup-shadow) !important;
          border: 0.5px solid var(--panel-border) !important;
        }
        .maplibregl-popup-tip { border-top-color: var(--popup-tip) !important; }
        .maplibregl-popup-close-button {
          color: var(--close-btn) !important; font-size: 18px !important;
          line-height: 1 !important; padding: 3px 7px !important;
          font-family: -apple-system, sans-serif !important;
          font-weight: 300 !important; background: transparent !important;
        }
        .maplibregl-popup-close-button:hover {
          color: var(--close-hover) !important; background: transparent !important;
        }

        .prop-table {
          width: 100%; border-collapse: collapse;
          display: block; max-height: 228px; overflow-y: auto;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          font-size: 11.5px;
        }
        .prop-table tr { border-bottom: 0.5px solid var(--sep); }
        .prop-table tr:last-child { border-bottom: none; }
        .prop-key {
          font-weight: 600; color: var(--label2);
          padding: 5px 6px 5px 12px; vertical-align: top; white-space: nowrap;
        }
        .prop-val {
          font-family: ui-monospace, 'SF Mono', 'Menlo', monospace;
          font-size: 10.5px; color: var(--label);
          padding: 5px 12px 5px 0; vertical-align: top; word-break: break-all;
        }
        .no-props { padding: 10px 12px; font: 11px -apple-system, sans-serif; color: var(--label3); }

        .maplibregl-ctrl-group {
          border-radius: 8px !important;
          background: var(--panel-bg) !important;
          border: 0.5px solid var(--panel-border) !important;
          box-shadow: var(--panel-shadow) !important;
          backdrop-filter: blur(20px) saturate(180%) !important;
          -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
          overflow: hidden;
        }
        .maplibregl-ctrl-group button {
          width: 30px !important; height: 30px !important;
          background-color: transparent !important; color: var(--label) !important;
        }
        .maplibregl-ctrl-group button:hover { background-color: var(--sep) !important; }
        .maplibregl-ctrl-group button + button { border-top: 0.5px solid var(--sep) !important; }
        .maplibregl-ctrl-zoom-in .maplibregl-ctrl-icon,
        .maplibregl-ctrl-zoom-out .maplibregl-ctrl-icon,
        .maplibregl-ctrl-compass .maplibregl-ctrl-icon { filter: var(--icon-filter); }
        .maplibregl-ctrl-bottom-left {
          top: 68px !important; bottom: auto !important;
          left: 10px !important; transform: none !important;
        }
        .maplibregl-ctrl-bottom-left > .maplibregl-ctrl { margin: 0 !important; }
        .maplibregl-ctrl-scale {
          background: var(--panel-bg) !important;
          border: 0.5px solid var(--label2) !important; border-top: none !important;
          color: var(--label2) !important; font: 10px -apple-system, sans-serif !important;
          backdrop-filter: blur(20px) saturate(180%) !important;
          -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
          border-radius: 0 0 4px 4px !important; padding: 1px 4px !important;
        }
        .maplibregl-ctrl-attrib {
          background: var(--panel-bg) !important;
          border: 0.5px solid var(--panel-border) !important;
          box-shadow: var(--panel-shadow) !important;
          backdrop-filter: blur(20px) saturate(180%) !important;
          -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
          border-radius: 8px !important;
        }
        .maplibregl-ctrl-attrib-inner,
        .maplibregl-ctrl-attrib-inner a {
          color: var(--label2) !important;
        }
        .maplibregl-ctrl-attrib-button {
          background-color: transparent !important;
          filter: var(--icon-filter) !important;
        }

        /* ── Table view ──────────────────────────────────────── */
        #table-view {
          position: absolute; top: 48px; left: 0; right: 0; bottom: 0;
          z-index: 200; display: none;
          background: var(--bg); overflow: auto;
        }
        .attr-table {
          width: 100%; border-collapse: collapse;
          font: 12px -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
        }
        .attr-table thead th {
          position: sticky; top: 0; z-index: 1;
          background: var(--panel-bg);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
          padding: 8px 12px;
          font-weight: 600; font-size: 11px;
          color: var(--label2);
          text-align: left; white-space: nowrap;
          border-bottom: 0.5px solid var(--sep);
        }
        .attr-table tbody tr {
          border-bottom: 0.5px solid var(--sep);
        }
        .attr-table tbody tr:hover { background: var(--panel-bg); }
        .attr-table tbody tr.selected {
          background: var(--panel-bg);
          box-shadow: inset 3px 0 0 var(--accent);
        }
        .attr-table td {
          padding: 6px 12px; color: var(--label);
          font-size: 12px; white-space: nowrap;
          max-width: 300px; overflow: hidden;
          text-overflow: ellipsis; vertical-align: middle;
        }
        .attr-table td:first-child {
          padding: 6px 8px;
          vertical-align: middle;
        }
        .btn-show-map {
          display: inline-flex; align-items: center; justify-content: center;
          width: 24px; height: 24px;
          border: none; border-radius: 6px; cursor: pointer;
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          color: var(--accent);
          transition: background 0.15s;
        }
        .btn-show-map:hover { background: var(--sep); }
        .attr-type {
          display: inline-block; font-size: 10px; font-weight: 500;
          color: var(--accent);
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          border-radius: 4px; padding: 2px 6px;
        }
        .attr-val-mono {
          font-family: ui-monospace, 'SF Mono', 'Menlo', monospace;
          font-size: 11px; color: var(--label2);
        }
        #table-loading {
          position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
          text-align: center; color: var(--label3);
          font: 13px -apple-system, BlinkMacSystemFont, sans-serif;
        }
        #table-loading .spinner {
          width: 20px; height: 20px; margin: 0 auto 10px;
          border: 2px solid var(--sep); border-top-color: var(--accent);
          border-radius: 50%;
          animation: spin 0.8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* ── View toggle ─────────────────────────────────────── */
        #view-toggle {
          position: absolute; z-index: 300;
          top: 10px; left: 50%; transform: translateX(-50%);
          display: flex; border-radius: 8px; overflow: hidden;
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          box-shadow: var(--panel-shadow);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
        }
        #view-toggle button {
          width: 30px; height: 30px;
          border: none; background: transparent; cursor: pointer;
          display: flex; align-items: center; justify-content: center;
          color: var(--label);
        }
        #view-toggle button:hover { background: var(--sep); }
        #view-toggle button.active { background: var(--accent); color: #fff; }
        #view-toggle button + button { border-left: 0.5px solid var(--sep); }
      </style>
    </head>
    <body>
      <div id="stats" class="panel"></div>
      <div id="basemap-notice" class="panel" role="status" hidden></div>
      <div id="coords" class="panel"></div>
      <div id="map"></div>
      <div id="table-view"></div>
      <div id="view-toggle">
        <button id="btn-map" class="active" title="Map view" aria-label="Map view">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1 4l4.5-2.5 5 2.5L15 1.5v11L10.5 15l-5-2.5L1 15z"/><path d="M5.5 1.5v11M10.5 4v11"/></svg>
        </button>
        <button id="btn-table" title="Table view" aria-label="Table view">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5"/><line x1="1.5" y1="6.5" x2="14.5" y2="6.5"/><line x1="1.5" y1="10.5" x2="14.5" y2="10.5"/><line x1="6" y1="6.5" x2="6" y2="13.5"/></svg>
        </button>
      </div>
      <script src="maplibre-gl.js"></script>
      <script>
        var META = \(metaJSON);

        var typeLabels = {
          'Point':'Point',             'MultiPoint':'Multi\\u00b7Point',
          'LineString':'Line',          'MultiLineString':'Multi\\u00b7Line',
          'Polygon':'Polygon',          'MultiPolygon':'Multi\\u00b7Polygon',
          'GeometryCollection':'Collection'
        };
        var typeNames = META.geometryTypes.map(function(t) {
          return typeLabels[t] || t;
        }).join('  \\u00b7  ');

        document.getElementById('stats').innerHTML =
          '<div class="stats-count">'  + META.featureCount.toLocaleString() +
          '&#x2009;feature' + (META.featureCount !== 1 ? 's' : '') + '</div>' +
          (typeNames ? '<div class="stats-types">' + esc(typeNames) + '</div>' : '') +
          (META.vertexCount > 0 ? '<div class="stats-vertices">' +
            META.vertexCount.toLocaleString() + '&#x2009;' +
            (META.vertexCount === 1 ? 'vertex' : 'vertices') + '</div>' : '');

        var isDark      = window.matchMedia('(prefers-color-scheme: dark)').matches;
        var bgColor     = isDark ? '#1c1c1e' : '#f2f2f7';
        var dataColor   = isDark ? '#f97316' : '#c2410c';
        var fillOpacity = isDark ? 0.25      : 0.15;
        var emptyFC     = { type: 'FeatureCollection', features: [] };
        // Incremented on each appearance change so a slow response cannot
        // replace a newer style. The plain background stays until a style
        // document has been fetched.
        var basemapGeneration = 0;

        // OpenFreeMap's public styles: no API key, no per-view billing.
        // Positron and Dark match the old light_all / dark_all pairing.
        // Attribution is inside the TileJSON (OpenFreeMap, OpenMapTiles, OSM)
        // and MapLibre adds it when that source loads.
        function basemapURL(dark) {
          return dark
            ? 'https://tiles.openfreemap.org/styles/dark'
            : 'https://tiles.openfreemap.org/styles/positron';
        }

        function plainStyle(color) {
          return {
            version: 8,
            sources: {},
            layers: [{ id: 'bg', type: 'background', paint: { 'background-color': color } }]
          };
        }

        // Carry GeoJSON layers across a basemap swap. The plain background
        // layer is not copied; the OpenFreeMap style has its own.
        function keepDataLayers(previous, next) {
          if (!previous || !previous.sources) return next;
          if (previous.sources.data) next.sources.data = previous.sources.data;
          if (previous.sources.highlight) next.sources.highlight = previous.sources.highlight;
          var keep = { fill: 1, line: 1, circle: 1, 'hl-fill': 1, 'hl-line': 1, 'hl-circle': 1 };
          var extra = (previous.layers || []).filter(function(layer) { return keep[layer.id]; });
          next.layers = (next.layers || []).concat(extra);
          return next;
        }

        function paintData() {
          var color  = isDark ? '#f97316' : '#c2410c';
          var fill   = isDark ? 0.25      : 0.15;
          var hlFill = isDark ? 0.50      : 0.35;
          var stroke = isDark ? '#000000' : '#ffffff';
          var bg     = isDark ? '#1c1c1e' : '#f2f2f7';
          if (!map.getLayer) return;
          if (map.getLayer('bg')) map.setPaintProperty('bg', 'background-color', bg);
          if (map.getLayer('fill')) {
            map.setPaintProperty('fill', 'fill-color', color);
            map.setPaintProperty('fill', 'fill-opacity', fill);
          }
          if (map.getLayer('line')) map.setPaintProperty('line', 'line-color', color);
          if (map.getLayer('circle')) {
            map.setPaintProperty('circle', 'circle-color', color);
            map.setPaintProperty('circle', 'circle-stroke-color', stroke);
          }
          if (map.getLayer('hl-fill')) {
            map.setPaintProperty('hl-fill', 'fill-color', color);
            map.setPaintProperty('hl-fill', 'fill-opacity', hlFill);
          }
        }

        // One report per basemap load. Tile errors arrive in a burst; style.load
        // re-arms the latch so a later tile or sprite failure still reports once.
        var basemapNotedFailure = -1;
        var basemapNotedSuccess = -1;
        var basemapAppliedGeneration = -1;
        var basemapAppliedURL = '';

        function showBasemapNotice() {
          var el = document.getElementById('basemap-notice');
          if (!el) return;
          // Fixed label. Error text goes to the log, never the page.
          el.textContent = 'Basemap unavailable';
          el.hidden = false;
        }

        function hideBasemapNotice() {
          var el = document.getElementById('basemap-notice');
          if (el) el.hidden = true;
        }

        function postBasemap(payload) {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.basemap) {
            window.webkit.messageHandlers.basemap.postMessage(payload);
          }
        }

        function noteBasemapFailure(generation, message, url) {
          if (generation !== basemapGeneration) return;
          if (basemapNotedFailure === generation) return;
          basemapNotedFailure = generation;
          showBasemapNotice();
          postBasemap({
            ok: false,
            message: String(message || 'basemap failed'),
            url: String(url || '')
          });
        }

        function noteBasemapSuccess(generation, url) {
          if (generation !== basemapGeneration) return;
          if (basemapNotedSuccess === generation) return;
          basemapNotedSuccess = generation;
          basemapNotedFailure = -1;
          hideBasemapNotice();
          postBasemap({ ok: true, message: '', url: String(url || '') });
        }

        // GeoJSON problems use the data and highlight sources. A different
        // source id, a tile, or the style host is the basemap.
        function basemapErrorInfo(e) {
          if (!e || !e.error) return null;
          var sourceId = e.sourceId || (e.source && e.source.id) || '';
          if (sourceId === 'data' || sourceId === 'highlight') return null;
          var message = e.error.message ? String(e.error.message) : '';
          var url = e.error.url ? String(e.error.url) : '';
          if (!message && !url) return null;
          if (message.indexOf('GeoJSON') !== -1) return null;
          if (message === 'AbortError' || message.indexOf('abort') !== -1 || message.indexOf('Abort') !== -1) return null;
          if (sourceId || e.tile) {
            return { message: message || ('basemap source ' + (sourceId || 'tile')), url: url };
          }
          var haystack = message + ' ' + url;
          if (haystack.indexOf('openfreemap.org') !== -1
              || message.indexOf('AJAXError:') === 0
              || message === 'Failed to fetch'
              || message === 'Load failed'
              || haystack.indexOf('NSURLErrorDomain') !== -1
              || haystack.indexOf('NetworkError') !== -1) {
            return { message: message, url: url };
          }
          var sourceMatch = /on source "([^"]+)"/.exec(message);
          if (sourceMatch && sourceMatch[1] !== 'data' && sourceMatch[1] !== 'highlight') {
            return { message: message, url: url };
          }
          return null;
        }

        // fetch() is a subresource load. The WKNavigationDelegate only sees
        // document navigations and link clicks, so it does not cancel style,
        // tile, glyph, or sprite requests. A failed fetch leaves the plain
        // background; geometry keeps drawing.
        function applyBasemap(dark) {
          var generation = ++basemapGeneration;
          var url = basemapURL(dark);
          if (typeof fetch !== 'function') {
            noteBasemapFailure(generation, 'fetch unavailable', url);
            return;
          }
          fetch(url).then(function(response) {
            if (!response.ok) throw new Error('HTTP ' + response.status);
            return response.json();
          }).then(function(style) {
            if (generation !== basemapGeneration) return;
            if (!style || style.version !== 8) {
              noteBasemapFailure(generation, 'style document was not a MapLibre style', url);
              return;
            }
            basemapAppliedGeneration = generation;
            basemapAppliedURL = url;
            try {
              map.setStyle(style, { diff: false, validate: false, transformStyle: keepDataLayers });
            } catch (err) {
              if (basemapAppliedGeneration === generation) basemapAppliedGeneration = -1;
              noteBasemapFailure(generation, err && err.message ? String(err.message) : 'setStyle failed', url);
            }
          }).catch(function(err) {
            var message = err && err.message ? String(err.message) : 'fetch failed';
            noteBasemapFailure(generation, message, url);
          });
        }

        var mapOptions = {
          container: 'map',
          style: plainStyle(bgColor),
          // An options object replaces the library default. compact is
          // already the default, and the MapLibre credit has to be repeated
          // or the control is empty until a basemap source arrives. Empty
          // attributions skip the compact class, and the next update would
          // expand the control again.
          attributionControl: {
            compact: true,
            customAttribution: '<a href="https://maplibre.org/" target="_blank">MapLibre</a>'
          }
        };

        if (META.bounds) {
          mapOptions.bounds           = META.bounds;
          mapOptions.fitBoundsOptions = { padding: 40, maxZoom: 16 };
        } else {
          mapOptions.center = [0, 20];
          mapOptions.zoom   = 1;
        }

        var map = new maplibregl.Map(mapOptions);

        // The compact control is created expanded (maplibregl-compact-show
        // and open). Drop both so it starts as the (i) button. A click still
        // opens the credits. With the compact class already set, later
        // source attributions do not expand it again.
        var attrib = document.querySelector('.maplibregl-ctrl-attrib');
        if (attrib) {
          attrib.classList.remove('maplibregl-compact-show');
          attrib.removeAttribute('open');
        }

        map.on('error', function(e) {
          var info = basemapErrorInfo(e);
          if (!info) return;
          var generation = basemapAppliedGeneration > 0 ? basemapAppliedGeneration : basemapGeneration;
          noteBasemapFailure(generation, info.message, info.url || basemapAppliedURL);
        });

        map.on('style.load', function() {
          if (basemapAppliedGeneration < 0 || basemapAppliedGeneration !== basemapGeneration) return;
          var style = map.getStyle ? map.getStyle() : null;
          var sources = (style && style.sources) || {};
          var remote = false;
          for (var id in sources) {
            if (id !== 'data' && id !== 'highlight') { remote = true; break; }
          }
          if (!remote) return;
          noteBasemapSuccess(basemapAppliedGeneration, basemapAppliedURL);
        });

        map.addControl(new maplibregl.NavigationControl(), 'top-right');
        map.addControl({
          onAdd: function() {
            var div = document.createElement('div');
            div.className = 'maplibregl-ctrl maplibregl-ctrl-group';
            var btn = document.createElement('button');
            btn.title = 'Fit to data';
            btn.setAttribute('aria-label', 'Fit to data');
            btn.style.cssText = 'display:flex;align-items:center;justify-content:center;';
            btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="16" height="16" fill="currentColor"><path d="M2 2h4v1.5H3.5V5H2zm10 0h4v3h-1.5V3.5H12zM2 16v-4h1.5v2.5H6V16zm10 0v-1.5h2.5V12H16v4z"/></svg>';
            btn.onclick = fitToData;
            div.appendChild(btn);
            return div;
          },
          onRemove: function() {}
        }, 'top-right');
        map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left');

        // Position scale bar below stats panel, match its width
        requestAnimationFrame(function() {
          var st = document.getElementById('stats');
          var sc = document.querySelector('.maplibregl-ctrl-bottom-left');
          if (st && sc) {
            var r = st.getBoundingClientRect();
            sc.style.top = (r.bottom + 4) + 'px';
            var bar = sc.querySelector('.maplibregl-ctrl-scale');
            if (bar) bar.style.maxWidth = r.width + 'px';
          }
        });

        function fitToData() {
          if (META.bounds) map.fitBounds(META.bounds, { padding: 40, maxZoom: 16 });
        }

        function esc(s) {
          return String(s)
            .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
            .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
        }

        var activePopup = null;
        var closingProgrammatically = false;

        function closeActivePopup() {
          if (!activePopup) return;
          closingProgrammatically = true;
          activePopup.remove();
          closingProgrammatically = false;
          activePopup = null;
        }

        // ── View toggle state ────────────────────────────────
        var currentView = 'map';
        var tableBuilt  = false;
        var features    = [];
        var selectedFeatureIndex = -1;

        function selectRow(idx) {
          if (tableBuilt) {
            var prev = document.querySelector('.attr-table tbody tr.selected');
            if (prev) prev.classList.remove('selected');
            if (idx >= 0) {
              var r = document.getElementById('row-' + idx);
              if (r) r.classList.add('selected');
            }
          }
          selectedFeatureIndex = idx;
        }

        function featureBounds(f) {
          if (!f.geometry || !f.geometry.coordinates) return null;
          var n = 0, b = new maplibregl.LngLatBounds();
          (function walk(c) {
            if (typeof c[0] === 'number') { b.extend([c[0], c[1]]); n++; }
            else c.forEach(walk);
          })(f.geometry.coordinates);
          return n ? b : null;
        }

        function buildTable() {
          var el = document.getElementById('table-view');
          if (!features.length) {
            el.innerHTML = '<p style="padding:40px;text-align:center;color:var(--label3);' +
              'font:13px -apple-system,sans-serif">No features</p>';
            tableBuilt = true; return;
          }
          // Show spinner, defer heavy work so the UI updates first
          el.innerHTML = '<div id="table-loading"><div class="spinner"></div>Loading ' +
            features.length.toLocaleString() + ' feature' + (features.length !== 1 ? 's' : '') + '\\u2026</div>';
          tableBuilt = true;
          setTimeout(function() {
            var allKeys = [], ks = {};
            features.forEach(function(f) {
              Object.keys(f.properties || {}).forEach(function(k) {
                if (k !== '__idx' && !ks[k]) { ks[k] = true; allKeys.push(k); }
              });
            });
            var mapIcon = '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M1 4l4.5-2.5 5 2.5L15 1.5v11L10.5 15l-5-2.5L1 15z"/><path d="M5.5 1.5v11M10.5 4v11"/></svg>';
            var h = '<table class="attr-table"><thead><tr><th></th><th>#</th><th>Type</th>';
            allKeys.forEach(function(k) { h += '<th>' + esc(k) + '</th>'; });
            h += '</tr></thead><tbody>';
            features.forEach(function(f, i) {
              var gt = (f.geometry && f.geometry.type) || '\\u2014';
              var p  = f.properties || {};
              h += '<tr id="row-' + i + '" data-idx="' + i + '"';
              if (i === selectedFeatureIndex) h += ' class="selected"';
              h += '><td><button class="btn-show-map" data-idx="' + i + '" title="Show on Map">' + mapIcon + '</button></td>';
              h += '<td>' + (i + 1) + '</td>';
              h += '<td><span class="attr-type">' + esc(typeLabels[gt] || gt) + '</span></td>';
              allKeys.forEach(function(k) {
                var v = p[k];
                if (v === undefined || v === null) {
                  h += '<td style="color:var(--label3)">\\u2014</td>';
                } else if (typeof v === 'object') {
                  h += '<td class="attr-val-mono">' + esc(JSON.stringify(v)) + '</td>';
                } else {
                  h += '<td>' + esc(String(v)) + '</td>';
                }
              });
              h += '</tr>';
            });
            h += '</tbody></table>';
            el.innerHTML = h;
            el.querySelectorAll('.btn-show-map').forEach(function(btn) {
              btn.addEventListener('click', function(e) {
                e.stopPropagation();
                var idx = parseInt(this.dataset.idx);
                selectRow(idx);
                var f = features[idx];
                if (f) {
                  map.getSource('highlight').setData(f);
                  // Switch to map first, then fit bounds after resize
                  toggleView('map');
                  setTimeout(function() {
                    map.resize();
                    var fb = featureBounds(f);
                    if (fb) {
                      var sw = fb.getSouthWest(), ne = fb.getNorthEast();
                      if (sw.lng === ne.lng && sw.lat === ne.lat)
                        map.flyTo({ center: [sw.lng, sw.lat], zoom: 14 });
                      else
                        map.fitBounds(fb, { padding: 80, maxZoom: 16 });
                    }
                  }, 50);
                }
              });
            });
            if (selectedFeatureIndex >= 0) {
              var sr = document.getElementById('row-' + selectedFeatureIndex);
              if (sr) { sr.classList.add('selected'); sr.scrollIntoView({ block: 'center' }); }
            }
          }, 16);
        }

        function toggleView(view) {
          if (view === currentView) return;
          currentView = view;
          var mapEl    = document.getElementById('map');
          var tableEl  = document.getElementById('table-view');
          var statsEl  = document.getElementById('stats');
          var coordsEl = document.getElementById('coords');
          if (view === 'table') {
            if (!tableBuilt) buildTable();
            closeActivePopup();
            mapEl.style.display    = 'none';
            tableEl.style.display  = 'block';
            statsEl.style.display  = 'none';
            coordsEl.style.display = 'none';
            document.getElementById('btn-map').classList.remove('active');
            document.getElementById('btn-table').classList.add('active');
            if (selectedFeatureIndex >= 0) {
              var sr = document.getElementById('row-' + selectedFeatureIndex);
              if (sr) sr.scrollIntoView({ block: 'center' });
            }
          } else {
            tableEl.style.display  = 'none';
            mapEl.style.display    = 'block';
            statsEl.style.display  = '';
            coordsEl.style.display = '';
            coordsEl.style.visibility = 'hidden';
            document.getElementById('btn-map').classList.add('active');
            document.getElementById('btn-table').classList.remove('active');
            setTimeout(function() { map.resize(); }, 0);
          }
        }

        document.getElementById('btn-map').onclick  = function() { toggleView('map'); };
        document.getElementById('btn-table').onclick = function() { toggleView('table'); };

        map.on('load', function() {

          // CSS custom properties follow the appearance on their own. The
          // basemap URL and GeoJSON paint are set from JS, so they do not.
          window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
            isDark = e.matches;
            paintData();
            applyBasemap(isDark);
          });
          // Started before GeoJSON is parsed. fetch resolves on a later turn,
          // after the data layers below exist, and keepDataLayers copies them.
          applyBasemap(isDark);

          // Parse GeoJSON injected by Swift as window.__GEO__ (base64)
          var geojson;
          try {
            var bin = atob(window.__GEO__ || '');
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            geojson = JSON.parse(new TextDecoder().decode(bytes));
          }
          catch(e) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mapReady) {
              window.webkit.messageHandlers.mapReady.postMessage(null);
            }
            return;
          }

          // Normalise into a flat feature array with __idx for table↔map linking
          if (geojson.type === 'FeatureCollection') {
            features = geojson.features || [];
          } else if (geojson.type === 'Feature') {
            features = [geojson];
          } else {
            features = [{ type: 'Feature', geometry: geojson, properties: {} }];
          }
          features.forEach(function(f, i) {
            if (!f.properties) f.properties = {};
            f.properties.__idx = i;
          });

          map.addSource('data', { type: 'geojson', data: { type: 'FeatureCollection', features: features } });

          map.addLayer({
            id: 'fill', type: 'fill', source: 'data',
            filter: ['==', '$type', 'Polygon'],
            paint: { 'fill-color': dataColor, 'fill-opacity': fillOpacity }
          });
          map.addLayer({
            id: 'line', type: 'line', source: 'data',
            filter: ['in', '$type', 'Polygon', 'LineString'],
            paint: { 'line-color': dataColor, 'line-width': 2, 'line-opacity': 0.9 }
          });
          map.addLayer({
            id: 'circle', type: 'circle', source: 'data',
            filter: ['==', '$type', 'Point'],
            paint: {
              'circle-radius': 6, 'circle-color': dataColor, 'circle-opacity': 0.9,
              'circle-stroke-width': 1.5,
              'circle-stroke-color': isDark ? '#000000' : '#ffffff'
            }
          });

          map.addSource('highlight', { type: 'geojson', data: emptyFC });
          map.addLayer({
            id: 'hl-fill', type: 'fill', source: 'highlight',
            filter: ['==', '$type', 'Polygon'],
            paint: { 'fill-color': dataColor, 'fill-opacity': isDark ? 0.5 : 0.35 }
          });
          map.addLayer({
            id: 'hl-line', type: 'line', source: 'highlight',
            filter: ['in', '$type', 'Polygon', 'LineString'],
            paint: { 'line-color': '#ffffff', 'line-width': 2.5, 'line-opacity': 0.9 }
          });
          map.addLayer({
            id: 'hl-circle', type: 'circle', source: 'highlight',
            filter: ['==', '$type', 'Point'],
            paint: {
              'circle-radius': 8, 'circle-color': dataColor, 'circle-opacity': 1,
              'circle-stroke-width': 2.5, 'circle-stroke-color': '#ffffff'
            }
          });

          ['fill', 'line', 'circle'].forEach(function(id) {
            map.on('mouseenter', id, function() { map.getCanvas().style.cursor = 'pointer'; });
            map.on('mouseleave', id, function() { map.getCanvas().style.cursor = ''; });
          });

          map.on('click', function(e) {
            var hits = map.queryRenderedFeatures(e.point, { layers: ['fill', 'line', 'circle'] });
            if (!hits.length) {
              map.getSource('highlight').setData(emptyFC);
              closeActivePopup();
              selectRow(-1);
              return;
            }
            map.getSource('highlight').setData(hits[0]);
            closeActivePopup();

            var props   = hits[0].properties || {};
            if (props.__idx !== undefined) selectRow(props.__idx);
            var keys    = Object.keys(props).filter(function(k) { return k !== '__idx'; });
            var content = keys.length === 0
              ? '<p class="no-props">No properties</p>'
              : '<table class="prop-table">' + keys.map(function(k) {
                  var v = props[k];
                  // MapLibre 6 returns nested property values as objects.
                  var shown = (v !== null && typeof v === 'object') ? JSON.stringify(v) : v;
                  return '<tr><td class="prop-key">' + esc(k) +
                         '</td><td class="prop-val">' + esc(shown === null ? '\\u2014' : shown) +
                         '</td></tr>';
                }).join('') + '</table>';

            activePopup = new maplibregl.Popup({
              closeButton: true, closeOnClick: false,
              maxWidth: '260px', offset: 8
            }).setLngLat(e.lngLat).setHTML(content).addTo(map);

            activePopup.on('close', function() {
              activePopup = null;
              if (!closingProgrammatically) {
                map.getSource('highlight').setData(emptyFC);
                selectRow(-1);
              }
            });
          });

          var coordsEl = document.getElementById('coords');
          var canvas   = map.getCanvas();
          canvas.addEventListener('mousemove', function(e) {
            var rect   = canvas.getBoundingClientRect();
            var lngLat = map.unproject([e.clientX - rect.left, e.clientY - rect.top]);
            coordsEl.textContent = lngLat.lng.toFixed(5) + ',  ' + lngLat.lat.toFixed(5);
            coordsEl.style.visibility = 'visible';
          });
          canvas.addEventListener('mouseleave', function() {
            coordsEl.style.visibility = 'hidden';
          });

          // Signal Swift: map is ready (spinner dismiss in QL extension, no-op in app)
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mapReady) {
            window.webkit.messageHandlers.mapReady.postMessage(null);
          }
        });
      </script>
    </body>
    </html>
    """
}
