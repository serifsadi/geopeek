// Exercises the real parser and HTML builder in Shared/GeoRenderer.swift.
//
//   swiftc -o /tmp/verify-html-safety \
//     Shared/GeoRenderer.swift test-fixtures/verify-html-safety.swift
//   /tmp/verify-html-safety
//
// Not part of an Xcode target. Confirms a malicious GeoJSON file cannot break
// out of the generated <script> or the injected user script, that the
// navigation policy refuses every load except the map document itself, and
// that the plain-JSON fallback escapes file text the same way.

import Foundation

var failures = 0

func fail(_ message: String) {
    failures += 1
    fputs("FAIL: \(message)\n", stderr)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

func show(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        .replacingOccurrences(of: "\n", with: "\\n")
}

/// Evaluate a JS expression with Node. Independent of JSONSerialization.
func evalJS(_ expression: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "node", "-e",
        "let s='';process.stdin.setEncoding('utf8');" +
        "process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{" +
        "try{const v=Function('return ('+s+');')();" +
        "process.stdout.write(typeof v==='string'?v:JSON.stringify(v));}" +
        "catch(e){process.stderr.write(String(e));process.exit(2);}});"
    ]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data(expression.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderrText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw NSError(domain: "verify", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: "node rejected \(show(expression)): \(stderrText)"
        ])
    }
    return stdout
}

func roundTripJSONString(_ value: String) throws -> String {
    let literal = scriptSafeJSONString(value)
    for forbidden in ["<", ">", "&", "\u{2028}", "\u{2029}", "\n", "\r"] {
        if literal.contains(forbidden) {
            fail("scriptSafeJSONString still contains \(show(forbidden)) in \(show(literal))")
        }
    }
    check(literal.hasPrefix("\""), "JSON string does not start with a quote: \(show(literal))")
    let decoded = try evalJS(literal)
    check(decoded == value, "JS eval of \(show(literal)) produced \(show(decoded)), want \(show(value))")
    return literal
}

@main
enum VerifyHTMLSafety {
    static func main() {
        do {
            try run()
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}

func run() throws {
let breakouts = [
    "</script><script>alert(1)</script>",
    "</ScRiPt><SCRIPT>alert(1)</script >",
    "foo\";alert(1);//",
    "quote\"key\\",
    "value with \"quotes\" and \\ backslashes",
    "line\u{2028}sep",
    "value\u{2028}and\u{2029}tail",
    "a&b<c>d",
    "'single' and \"double\"",
    "<img src=x onerror=alert(1)>",
]

for payload in breakouts {
    _ = try roundTripJSONString(payload)
}

// The old template wrote geometry types in with raw quotes. The same payload
// closes the script element before any JS parser runs.
let oldTypesJS = "[" + breakouts.map { "\"\($0)\"" }.joined(separator: ",") + "]"
check(oldTypesJS.contains("</script><script>alert(1)</script>"),
      "fixture would not have broken the old interpolation")
check(oldTypesJS.contains("\u{2028}"),
      "fixture would not have put U+2028 in the old JS string")

// Even if a bad type skipped the whitelist, the JSON embedder still neutralizes it.
let forced = scriptSafeJSONObject(["geometryTypes": breakouts])
check(!forced.contains("<") && !forced.contains(">") && !forced.contains("&"),
      "forced JSON object still has HTML metacharacters: \(show(forced))")
check(!forced.contains("\u{2028}") && !forced.contains("\u{2029}"),
      "forced JSON object still has JS line separators")
let forcedJS = try evalJS(forced)
let forcedParsed = try JSONSerialization.jsonObject(with: Data(forcedJS.utf8)) as? [String: Any]
let forcedTypes = forcedParsed?["geometryTypes"] as? [String]
check(forcedTypes == breakouts, "JS eval of embedded JSON did not round-trip forced types: \(String(describing: forcedTypes))")

// --- Fixture ---

let fixtureURL = URL(fileURLWithPath: "test-fixtures/xss-breakout.geojson")
let fixture = try Data(contentsOf: fixtureURL)
guard let meta = parseGeoJSON(fixture) else {
    fail("fixture was rejected; a breakout type must not fail the whole file")
    throw NSError(domain: "verify", code: 1)
}

check(meta.geometryTypes == ["LineString", "Point"],
      "geometry types were not whitelisted: \(meta.geometryTypes)")
check(meta.featureCount == 3, "featureCount \(meta.featureCount)")
check(meta.vertexCount == 3, "vertexCount \(meta.vertexCount) (invalid geometries must not be walked)")
if let b = meta.bounds {
    check(b.minLng == 10 && b.maxLng == 12 && b.minLat == 20 && b.maxLat == 22,
          "bounds \(b.minLng),\(b.minLat) \(b.maxLng),\(b.maxLat)")
} else {
    fail("expected bounds from the valid Point and LineString only")
}

let html = makeMapHTML(meta: meta)
let forbiddenInPage = [
    "alert(1)",
    "</script><script>",
    "</ScRiPt",
    "property-key-breakout",
    "quote\"key",
    "foo\";alert(1)",
    "onerror",
    "\u{2028}",
    "\u{2029}",
]
for needle in forbiddenInPage {
    check(!html.contains(needle), "map HTML still contains \(show(needle))")
}

func countCaseInsensitive(_ needle: String, in text: String) -> Int {
    var count = 0
    var cursor = text.startIndex
    while let range = text.range(of: needle, options: [.caseInsensitive], range: cursor..<text.endIndex) {
        count += 1
        cursor = range.upperBound
    }
    return count
}

// The template closes the maplibre <script src> and the inline script. A
// breakout would add more end tags.
check(countCaseInsensitive("</script", in: html) == 2,
      "expected exactly two </script sequences, found \(countCaseInsensitive("</script", in: html))")

// Basemap is OpenFreeMap's keyless positron/dark styles. CARTO's raster host
// and the old opacity-gated layer must not come back.
check(html.contains("https://tiles.openfreemap.org/styles/dark"), "missing OpenFreeMap dark style")
check(html.contains("https://tiles.openfreemap.org/styles/positron"), "missing OpenFreeMap positron style")
check(html.contains("function plainStyle"), "missing plain-background fallback")
check(!html.contains("cartocdn.com") && !html.contains("carto.com"),
      "CARTO basemap is still referenced")
check(!html.contains("raster-opacity"), "raster fade gate is still in the page")

guard let inlineOpen = html.range(of: "<script>\n", options: .backwards) else {
    fail("inline map script missing")
    throw NSError(domain: "verify", code: 1)
}
let inlineRest = html[inlineOpen.upperBound...]
guard let inlineClose = inlineRest.range(of: "</script>") else {
    fail("inline map script not closed")
    throw NSError(domain: "verify", code: 1)
}
let inlineScript = String(inlineRest[..<inlineClose.lowerBound])
let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("geopeek-map-script.js")
try inlineScript.write(to: scriptFile, atomically: true, encoding: .utf8)
let syntax = Process()
syntax.executableURL = URL(fileURLWithPath: "/usr/bin/env")
syntax.arguments = ["node", "--check", scriptFile.path]
let syntaxErr = Pipe()
syntax.standardError = syntaxErr
try syntax.run()
syntax.waitUntilExit()
let syntaxText = String(data: syntaxErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
check(syntax.terminationStatus == 0, "generated map script failed node --check: \(syntaxText)")

guard let metaStart = html.range(of: "var META = ") else {
    fail("META assignment missing")
    throw NSError(domain: "verify", code: 1)
}
let afterMeta = html[metaStart.upperBound...]
guard let metaEnd = afterMeta.range(of: ";\n") else {
    fail("META assignment not terminated")
    throw NSError(domain: "verify", code: 1)
}
let metaJSON = String(afterMeta[..<metaEnd.lowerBound])
check(!metaJSON.contains("<") && !metaJSON.contains(">") && !metaJSON.contains("&"),
      "META JSON contains HTML metacharacters: \(show(metaJSON))")
let metaValue = try evalJS(metaJSON)
check(metaValue.contains("\"LineString\""), "META JS value missing LineString: \(metaValue)")
check(metaValue.contains("\"Point\""), "META JS value missing Point: \(metaValue)")
check(!metaValue.contains("alert"), "META JS value contains alert: \(metaValue)")
check(!metaValue.contains("<"), "META JS value contains <: \(metaValue)")

// Property text never enters the HTML. It is carried as base64 in a JSON string.
let script = geoJSONInjectionScript(base64: fixture.base64EncodedString())
check(script.hasPrefix("window.__GEO__=") && script.hasSuffix(";"), "user script shape: \(show(String(script.prefix(40))))")
check(!script.contains("<") && !script.contains("\n") && !script.contains("\u{2028}"),
      "user script is not a single safe line: \(show(String(script.prefix(80))))")
let encoded = String(script.dropFirst("window.__GEO__=".count).dropLast())
let decodedB64 = try evalJS(encoded)
check(decodedB64 == fixture.base64EncodedString(), "user script did not round-trip the file bytes")
check(!decodedB64.contains("<"), "base64 alphabet unexpectedly contains <")

// The page's own esc() is what later renders property keys and values.
// The page template is a dedented multiline string, so esc's closing brace
// is indented four spaces in the generated HTML.
let escSource: String = {
    guard let start = html.range(of: "function esc(s) {") else { return "" }
    let rest = html[start.upperBound...]
    guard let end = rest.range(of: "\n    }") else { return "" }
    return "function esc(s) {" + String(rest[..<end.upperBound])
}()
check(escSource.contains("function esc"), "could not find esc() in the page")
if escSource.contains("function esc") {
    for payload in breakouts {
        let expression = "(function(){\n\(escSource)\nreturn esc(\(scriptSafeJSONString(payload)));})()"
        let escaped = try evalJS(expression)
        check(!escaped.contains("<") && !escaped.contains(">") && !escaped.contains("\""),
              "esc() left HTML metacharacters in \(show(escaped)) for \(show(payload))")
        check(!escaped.contains("'"),
              "esc() left a raw quote in \(show(escaped))")
        check(escaped.contains("&lt;") || !payload.contains("<"),
              "esc() did not encode < from \(show(payload)): \(show(escaped))")
    }
}

// A root type outside the GeoJSON whitelist never reaches the map template.
// The filename cannot promote it: detection is the root `type` only.
let notGeoJSON = Data(#"{"type":"</script><script>alert(1)</script>","coordinates":[0,0]}"#.utf8)
check(parseGeoJSON(notGeoJSON) == nil, "a breakout root type should be rejected")
if case .map = renderPreview(data: notGeoJSON, fileName: "breakout.geojson") {
    fail("a .geojson name must not override the root type check")
}
check(!makeErrorHTML().contains("alert(1)"), "error page must stay static")

// No coordinates → null bounds, still valid JSON, no string interpolation.
let emptyFeature = Data(#"{"type":"Feature","geometry":null,"properties":{"name":"</script>"}}"#.utf8)
guard let emptyMeta = parseGeoJSON(emptyFeature) else {
    fail("null geometry should still parse")
    throw NSError(domain: "verify", code: 1)
}
check(emptyMeta.geometryTypes.isEmpty && emptyMeta.bounds == nil, "null geometry leaked a type or bounds")
let emptyHTML = makeMapHTML(meta: emptyMeta)
check(emptyHTML.contains("\"bounds\":null"), "missing null bounds in \(show(String(emptyHTML.suffix(200))))")
check(!emptyHTML.contains("alert") && !emptyHTML.contains("</script><script>"), "empty feature HTML contains payload")

// --- Navigation policy ---

let appBase = URL(string: "geopeek://r/")!
let appBaseNoSlash = URL(string: "geopeek://r")!
let carto = URL(string: "https://carto.com/attributions")!
let osm = URL(string: "https://openstreetmap.org/copyright")!
let evil = URL(string: "https://evil.example/collect")!
let jsURL = URL(string: "javascript:alert(1)")!
let fileSecret = URL(fileURLWithPath: "/etc/passwd")
let resources = URL(fileURLWithPath: "/PlugIns/GeoPeekExtension.appex/Contents/Resources", isDirectory: true)
let bundledJS = resources.appendingPathComponent("maplibre-gl.js")

func decision(_ kind: MapNavigationKind, _ url: URL?, main: Bool = true, base: URL? = nil) -> MapNavigationDecision {
    decideMapNavigation(kind: kind, url: url, isMainFrame: main, documentBaseURL: base)
}

check(decision(.documentLoad, appBase, base: appBase) == .allow, "app document load rejected")
check(decision(.documentLoad, appBaseNoSlash, base: appBase) == .allow, "geopeek://r without slash rejected")
check(decision(.documentLoad, URL(string: "geopeek://r/maplibre-gl.js"), base: appBase) == .cancel,
      "navigating the document to maplibre-gl.js was allowed")
check(decision(.documentLoad, URL(string: "geopeek://r/?x=1"), base: appBase) == .cancel,
      "query on the document URL was allowed")
check(decision(.documentLoad, URL(string: "geopeek://evil/"), base: appBase) == .cancel,
      "other geopeek host was allowed")
check(decision(.documentLoad, evil, base: appBase) == .cancel, "script navigation to https was allowed")
check(decision(.documentLoad, URL(string: "about:blank"), base: appBase) == .cancel,
      "about:blank allowed while a base URL is set")
check(decision(.documentLoad, appBase, main: false, base: appBase) == .cancel,
      "subframe load of the document URL was allowed")
check(decision(.documentLoad, nil, base: appBase) == .cancel, "nil URL document load was allowed")
check(decision(.other, appBase, base: appBase) == .cancel, "reload/form navigation was allowed")

check(decision(.documentLoad, URL(string: "about:blank"), base: nil) == .allow,
      "error page about:blank was rejected")
check(decision(.documentLoad, evil, base: nil) == .cancel,
      "https allowed when the document is about:blank")

check(decision(.documentLoad, resources, base: resources) == .allow, "Quick Look bundle base rejected")
check(decision(.documentLoad, bundledJS, base: resources) == .cancel, "bundle JS file allowed as the document")
check(decision(.documentLoad, fileSecret, base: resources) == .cancel, "arbitrary file URL allowed as the document")

check(decision(.linkActivated, carto, base: appBase) == .openExternally(carto), "https attribution not opened outside")
check(decision(.linkActivated, osm, base: appBase) == .openExternally(osm), "OSM attribution not opened outside")
let openFreeMap = URL(string: "https://openfreemap.org")!
let openMapTiles = URL(string: "https://www.openmaptiles.org/")!
check(decision(.linkActivated, openFreeMap, base: appBase) == .openExternally(openFreeMap),
      "OpenFreeMap attribution not opened outside")
check(decision(.linkActivated, openMapTiles, base: appBase) == .openExternally(openMapTiles),
      "OpenMapTiles attribution not opened outside")
// A style or tile URL is not a navigation the delegate is asked to judge.
// If one were delivered as a document load, it must not replace the preview.
let styleURL = URL(string: "https://tiles.openfreemap.org/styles/dark")!
let tileURL = URL(string: "https://tiles.openfreemap.org/planet/20261101_080013_pt/0/0/0.pbf")!
check(decision(.documentLoad, styleURL, base: appBase) == .cancel, "style URL allowed as the document")
check(decision(.documentLoad, tileURL, base: resources) == .cancel, "tile URL allowed as the document")
check(decision(.linkActivated, URL(string: "HTTPS://carto.com/attributions")!, base: appBase)
        == .openExternally(URL(string: "HTTPS://carto.com/attributions")!),
      "uppercase scheme not treated as a browser link")
check(decision(.linkActivated, jsURL, base: appBase) == .cancel, "javascript: link was not cancelled")
check(decision(.linkActivated, fileSecret, base: appBase) == .cancel, "file: link was not cancelled")
check(decision(.linkActivated, URL(string: "data:text/html,<script>alert(1)</script>")!, base: appBase) == .cancel,
      "data: link was not cancelled")
check(decision(.linkActivated, appBase, base: appBase) == .cancel, "geopeek link was opened or loaded")
check(decision(.linkActivated, nil, base: appBase) == .cancel, "nil link was not cancelled")

// --- JSON fallback ---

check(jsonFallbackMaxBytes == 5 * 1024 * 1024, "fallback cap should stay 5 MB")
check(formatByteCount(0) == "0 bytes", "0 bytes")
check(formatByteCount(1) == "1 byte", "1 byte")
check(formatByteCount(665) == "665 bytes", "665 bytes")
check(formatByteCount(1024) == "1 KB", "1 KB")
check(formatByteCount(1536) == "1.5 KB", "1.5 KB")
check(formatByteCount(jsonFallbackMaxBytes) == "5 MB", "5 MB")

let allowedTags: Set<String> = [
    "!doctype", "html", "/html", "head", "/head", "meta", "style", "/style",
    "body", "/body", "header", "/header", "div", "/div", "h1", "/h1",
    "p", "/p", "pre", "/pre", "span", "/span"
]
let allowedClasses: Set<String> = ["title", "size", "status", "note", "k", "s", "n", "l"]

func assertSafeMarkup(_ html: String, _ label: String) {
    check(!html.lowercased().contains("<script"), "\(label) contains a script tag")
    check(!html.lowercased().contains("</script"), "\(label) contains a script end tag")
    check(!html.contains("\u{2028}") && !html.contains("\u{2029}"),
          "\(label) contains a raw JS line separator")
    check(!html.lowercased().contains("href"), "\(label) contains an href")
    check(!html.contains("Not Valid GeoJSON"), "\(label) still shows the GeoJSON error card")
    var spanDepth = 0
    var i = html.startIndex
    while let lt = html[i...].firstIndex(of: "<") {
        let after = html.index(after: lt)
        guard after < html.endIndex, let gt = html[after...].firstIndex(of: ">") else {
            fail("\(label) has an unclosed tag")
            return
        }
        if html[after] == "!" {
            let decl = html[after..<gt].lowercased()
            check(decl.hasPrefix("!doctype"), "\(label) unknown declaration <\(decl)>")
            i = html.index(after: gt)
            continue
        }
        let inside = html[after..<gt]
        let parts = inside.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard let rawName = parts.first else {
            fail("\(label) has an empty tag")
            return
        }
        let name = String(rawName).lowercased()
        check(allowedTags.contains(name), "\(label) has disallowed tag <\(inside)>")
        if name == "span" { spanDepth += 1 }
        if name == "/span" { spanDepth -= 1; check(spanDepth >= 0, "\(label) closed a span it never opened") }
        for attr in parts.dropFirst() {
            let key = String(attr.split(separator: "=", maxSplits: 1)[0]).lowercased()
            check(key == "class" || key == "charset", "\(label) has disallowed attribute \(attr)")
            if key == "class" {
                let value = attr.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                check(value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2,
                      "\(label) has an unquoted class \(attr)")
                let cls = String(value.dropFirst().dropLast())
                check(allowedClasses.contains(cls), "\(label) has unexpected class \(cls)")
            }
        }
        i = html.index(after: gt)
    }
    check(spanDepth == 0, "\(label) left \(spanDepth) span(s) open")
}

func decodeEntities(_ text: String) -> String {
    var out = ""
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "&" {
            let rest = text[i...]
            let entities: [(String, String)] = [
                ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                ("&quot;", "\""), ("&#39;", "'"),
                ("&#x2028;", "\u{2028}"), ("&#x2029;", "\u{2029}")
            ]
            if let match = entities.first(where: { rest.hasPrefix($0.0) }) {
                out += match.1
                i = text.index(i, offsetBy: match.0.count)
                continue
            }
        }
        out.append(text[i])
        i = text.index(after: i)
    }
    return out
}

func preText(_ html: String) -> String {
    guard let open = html.range(of: "<pre>"),
          let close = html.range(of: "</pre>", range: open.upperBound..<html.endIndex) else {
        return ""
    }
    let inner = String(html[open.upperBound..<close.lowerBound])
    var stripped = ""
    var i = inner.startIndex
    while i < inner.endIndex {
        if inner[i] == "<" {
            guard let gt = inner[i...].firstIndex(of: ">") else { break }
            i = inner.index(after: gt)
            continue
        }
        stripped.append(inner[i])
        i = inner.index(after: i)
    }
    return decodeEntities(stripped)
}

func canonicalJSON(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? ""
}

let hostileObject: [String: Any] = [
    "</script>": "</script><script>alert(1)</script>",
    "quote": "he said \"hello\" and 'bye'",
    "sep": "line\u{2028}sep\u{2029}tail",
    "amp": "a&b<c>d",
    "pre": "</pre></style>",
]
let hostileName = "evil\".json</script>\u{2028}"
let hostileData = try JSONSerialization.data(withJSONObject: hostileObject)
check(parseGeoJSON(hostileData) == nil, "hostile object must not be GeoJSON")
let hostileHTML = makeJSONFallbackHTML(fileName: hostileName, data: hostileData)
assertSafeMarkup(hostileHTML, "hostile object")
check(hostileHTML.contains("evil&quot;.json&lt;/script&gt;&#x2028;"),
      "hostile file name was not escaped: \(show(hostileHTML))")
check(hostileHTML.contains("&lt;/script&gt;"), "script payload was dropped")
check(hostileHTML.contains("&amp;"), "ampersand was not escaped")
check(hostileHTML.contains("&#x2028;") && hostileHTML.contains("&#x2029;"),
      "line separators were not escaped as entities")
check(hostileHTML.contains("&#39;"), "single quote was not escaped")
check(hostileHTML.contains("&quot;"), "double quote was not escaped")
check(hostileHTML.contains("<span class=\"k\">"), "keys are not colored")
check(hostileHTML.contains("<span class=\"s\">"), "strings are not colored")
check(hostileHTML.contains("prefers-color-scheme: dark"), "fallback ignores dark appearance")
check(hostileHTML.contains(formatByteCount(hostileData.count)), "header is missing the file size")
check(!hostileHTML.contains("Not valid JSON"), "valid JSON was reported as a parse error")
check(!hostileHTML.contains("Showing the first"), "small JSON was truncated")
let hostileVisible = preText(hostileHTML)
let hostileParsed = try JSONSerialization.jsonObject(with: Data(hostileVisible.utf8))
check(try canonicalJSON(hostileParsed) == canonicalJSON(hostileObject),
      "fallback view did not round-trip hostile JSON: \(show(hostileVisible))")

// A fragment keeps the author's bytes, including a raw U+2028 inside a string.
let fragment = Data("\"</script>\u{2028}\\\"quoted\\\"\"\n".utf8)
let fragmentHTML = makeJSONFallbackHTML(fileName: "fragment.json", data: fragment)
assertSafeMarkup(fragmentHTML, "fragment")
let fragmentVisible = preText(fragmentHTML)
let fragmentValue = try JSONSerialization.jsonObject(with: Data(fragmentVisible.utf8), options: [.fragmentsAllowed]) as? String
check(fragmentValue == "</script>\u{2028}\"quoted\"",
      "fragment round-trip produced \(show(fragmentValue ?? "nil"))")
check(preText(makeJSONFallbackHTML(fileName: "empty.json", data: Data("{ }".utf8))) == "{}",
      "empty object was not collapsed")
check(preText(makeJSONFallbackHTML(fileName: "empty.json", data: Data("[ ]".utf8))) == "[]",
      "empty array was not collapsed")
let scientific = preText(makeJSONFallbackHTML(fileName: "n.json", data: Data("[-1.5e+10]".utf8)))
check(scientific.contains("-1.5e+10"), "number spelling changed: \(show(scientific))")

for literal in ["true", "false", "null"] {
    let data = Data(literal.utf8)
    let html = makeJSONFallbackHTML(fileName: "\(literal).json", data: data)
    assertSafeMarkup(html, literal)
    check(preText(html) == literal, "\(literal) was rewritten to \(show(preText(html)))")
    check(html.contains("<span class=\"l\">\(literal)</span>"), "\(literal) is not a literal span")
    if case .map = renderPreview(data: data, fileName: "\(literal).geojson") {
        fail("\(literal) was treated as GeoJSON")
    }
}

let geoTypes = [
    "FeatureCollection", "Feature",
    "Point", "MultiPoint", "LineString", "MultiLineString",
    "Polygon", "MultiPolygon", "GeometryCollection"
]
for geoType in geoTypes {
    let data = Data("{\"type\":\"\(geoType)\"}".utf8)
    if case .fallback = renderPreview(data: data, fileName: "notes.json") {
        fail("\(geoType) in a .json file was not detected as GeoJSON")
    }
}
for other in ["feature", "Point ", "Foo", ""] {
    let data = Data("{\"type\":\"\(other)\"}".utf8)
    if case .map = renderPreview(data: data, fileName: "data.geojson") {
        fail("type \(show(other)) was treated as GeoJSON because the name is .geojson")
    }
}
let arrayRoot = Data(#"[{"type":"Point","coordinates":[0,0]}]"#.utf8)
if case .map = renderPreview(data: arrayRoot, fileName: "points.geojson") {
    fail("a JSON array was treated as GeoJSON")
}

func loadFixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: "test-fixtures/\(name)"))
}

let plain = try loadFixture("plain-object.json")
let plainHTML = makeJSONFallbackHTML(fileName: "plain-object.json", data: plain)
assertSafeMarkup(plainHTML, "plain-object.json")
check(plainHTML.contains(">plain-object.json<"), "plain-object header is missing the file name")
check(plainHTML.contains(formatByteCount(plain.count)), "plain-object header is missing the size")
check(!plainHTML.contains("Not valid JSON"), "plain-object.json was called invalid JSON")
check(plainHTML.contains("<span class=\"k\">"), "plain-object keys are not colored")
check(plainHTML.contains("<span class=\"s\">"), "plain-object strings are not colored")
check(plainHTML.contains("<span class=\"n\">"), "plain-object numbers are not colored")
check(plainHTML.contains("<span class=\"l\">"), "plain-object literals are not colored")
let plainText = preText(plainHTML)
let plainVisible = try JSONSerialization.jsonObject(with: Data(plainText.utf8))
let plainOriginal = try JSONSerialization.jsonObject(with: plain)
check(try canonicalJSON(plainVisible) == canonicalJSON(plainOriginal),
      "plain-object.json did not round-trip")
if let nameAt = plainText.range(of: "\"name\""),
   let versionAt = plainText.range(of: "\"version\""),
   let activeAt = plainText.range(of: "\"active\"") {
    check(nameAt.lowerBound < versionAt.lowerBound && versionAt.lowerBound < activeAt.lowerBound,
          "pretty-printer reordered keys: \(show(plainText))")
} else {
    fail("plain-object.json is missing name/version/active in \(show(plainText))")
}
if case .map = renderPreview(data: plain, fileName: "plain-object.json") {
    fail("plain-object.json was rendered as a map")
}

let arrayFixture = try loadFixture("array.json")
let arrayHTML = makeJSONFallbackHTML(fileName: "array.json", data: arrayFixture)
assertSafeMarkup(arrayHTML, "array.json")
check(preText(arrayHTML).contains("alpha") && preText(arrayHTML).contains("beta"),
      "array.json dropped a label")
check(!arrayHTML.contains("Not valid JSON"), "array.json was called invalid JSON")
let arrayVisible = try JSONSerialization.jsonObject(with: Data(preText(arrayHTML).utf8))
let arrayOriginal = try JSONSerialization.jsonObject(with: arrayFixture)
check(try canonicalJSON(arrayVisible) == canonicalJSON(arrayOriginal), "array.json did not round-trip")
if case .map = renderPreview(data: arrayFixture, fileName: "array.geojson") {
    fail("array.json was treated as GeoJSON")
}

let invalid = try loadFixture("invalid.json")
let invalidHTML = makeJSONFallbackHTML(fileName: "invalid.json", data: invalid)
assertSafeMarkup(invalidHTML, "invalid.json")
check(invalidHTML.contains("Not valid JSON."), "invalid.json is missing the parse-error line")
check(invalidHTML.contains("this is not json"), "invalid.json dropped the raw text")
check(invalidHTML.contains(">invalid.json<"), "invalid.json header is missing the file name")
check(!invalidHTML.contains("<span"), "invalid JSON should not be syntax-colored")
if case .map = renderPreview(data: invalid, fileName: "invalid.geojson") {
    fail("invalid.json was treated as GeoJSON")
}

let point = try loadFixture("point.json")
guard let pointMeta = parseGeoJSON(point) else {
    fail("point.json was not detected as GeoJSON")
    throw NSError(domain: "verify", code: 1)
}
check(pointMeta.featureCount == 1, "point.json featureCount \(pointMeta.featureCount)")
check(pointMeta.geometryTypes == ["Point"], "point.json types \(pointMeta.geometryTypes)")
switch renderPreview(data: point, fileName: "point.json") {
case .map(let html, let script):
    check(html.contains("maplibregl"), "GeoJSON .json file did not render the map")
    check(!html.contains("Not valid JSON") && !html.contains("Not Valid GeoJSON"),
          "GeoJSON .json file rendered the error card")
    check(script.hasPrefix("window.__GEO__="), "GeoJSON .json file is missing the user script")
case .fallback:
    fail("point.json was shown as plain JSON")
}

// Over the cap: valid JSON keeps a raw prefix and is not called invalid.
let wideJSON = Data(("{\"k\":\"" + String(repeating: "a", count: 40) + "\"}").utf8)
let wideHTML = makeJSONFallbackHTML(fileName: "wide.json", data: wideJSON, maxBytes: 16)
assertSafeMarkup(wideHTML, "wide.json")
check(wideHTML.contains("Not valid JSON") == false, "oversize valid JSON was called invalid")
check(wideHTML.contains("Showing the first \(formatByteCount(16)) of \(formatByteCount(wideJSON.count))."),
      "oversize valid JSON note was \(show(wideHTML))")
check(!wideHTML.contains("<span"), "oversize JSON should not be pretty-printed")
let wideXs = preText(wideHTML).filter { $0 == "a" }.count
check(wideXs < 40, "oversize JSON did not truncate the prefix")

// Over the cap and not JSON: prefix, note, and the parse-error line together.
let garbage = Data(String(repeating: "x", count: 50).utf8)
let garbageHTML = makeJSONFallbackHTML(fileName: "garbage.json", data: garbage, maxBytes: 10)
assertSafeMarkup(garbageHTML, "garbage")
check(garbageHTML.contains("Not valid JSON."), "oversize invalid JSON is missing the parse-error line")
check(garbageHTML.contains("Showing the first 10 bytes of 50 bytes."),
      "oversize invalid note was wrong")
check(preText(garbageHTML).filter { $0 == "x" }.count == 10, "garbage prefix length")

// A multibyte character on the cut stays whole (U+00E9 is two UTF-8 bytes).
let accents = Data("ééé".utf8)
check(accents.count == 6, "é should be 2 bytes, got \(accents.count)")
let accentHTML = makeJSONFallbackHTML(fileName: "e.json", data: accents, maxBytes: 3)
assertSafeMarkup(accentHTML, "accents")
check(!accentHTML.contains("\u{FFFD}"), "UTF-8 prefix split a character")
check(preText(accentHTML) == "é", "expected one é, got \(show(preText(accentHTML)))")
check(accentHTML.contains("Showing the first 2 bytes of 6 bytes."), "accent note")

// Pretty-printing a file that still fits can exceed the cap. Truncate that text.
let prettySource = try JSONSerialization.data(withJSONObject: ["k": String(repeating: "b", count: 30)])
check(prettySource.count > 20, "fixture was too small to truncate")
let prettyHTML = makeJSONFallbackHTML(fileName: "pretty.json", data: prettySource, maxBytes: prettySource.count)
assertSafeMarkup(prettyHTML, "pretty truncation")
check(prettyHTML.contains("Showing the first"), "pretty-printed JSON over the cap was not truncated")
check(!prettyHTML.contains("Not valid JSON"), "truncated pretty JSON was called invalid")

if failures == 0 {
    print("ok: \(breakouts.count) payloads, fixture, user script, esc(), navigation policy")
    print("ok: JSON fallback (hostile object, fragment, 9 GeoJSON types, plain-object.json, array.json, invalid.json, point.json, truncation)")
} else {
    fputs("\(failures) failure(s)\n", stderr)
    exit(1)
}
}
