// Exercises the real parser and HTML builder in Shared/GeoRenderer.swift.
//
//   swiftc -o /tmp/verify-html-safety \
//     Shared/GeoRenderer.swift test-fixtures/verify-html-safety.swift
//   /tmp/verify-html-safety
//
// Not part of an Xcode target. Confirms a malicious GeoJSON file cannot break
// out of the generated <script> or the injected user script, and that the
// navigation policy refuses every load except the map document itself.

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
let notGeoJSON = Data(#"{"type":"</script><script>alert(1)</script>","coordinates":[0,0]}"#.utf8)
check(parseGeoJSON(notGeoJSON) == nil, "a breakout root type should be rejected")
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

if failures == 0 {
    print("ok: \(breakouts.count) payloads, fixture, user script, esc(), navigation policy")
} else {
    fputs("\(failures) failure(s)\n", stderr)
    exit(1)
}
}
