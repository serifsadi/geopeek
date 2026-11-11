// Exercises the KML, KMZ, and GPX converters in Shared/GeoJSONImport.swift
// and the render hand-off in Shared/GeoRenderer.swift.
//
//   swiftc -swift-version 5 -o /tmp/verify-geo-import \
//     Shared/GeoJSONImport.swift Shared/GeoRenderer.swift \
//     test-fixtures/verify-geo-import.swift
//   /tmp/verify-geo-import
//
// On Linux the SDK has no zlib module. Point -I at a directory whose
// module.modulemap declares module zlib (header zlib.h, link "z").
// XMLParser is in FoundationXML there. Run this from the repository root.
//
// test-fixtures/sample.kmz is sample.kml deflated as doc.kml, written after
// a root other.kml and a nested kml, so the reader has to choose doc.kml.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

var failures = 0

func fail(_ message: String) {
    failures += 1
    fputs("FAIL: \(message)\n", stderr)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

func canon(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return text
}

func load(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: "test-fixtures/\(name)"))
}

func featureList(in data: Data) -> [[String: Any]]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["features"] as? [[String: Any]]
}

func feature(_ features: [[String: Any]], _ name: String) -> [String: Any]? {
    features.first { ($0["properties"] as? [String: Any])?["name"] as? String == name }
}

func geometry(_ feature: [String: Any]) -> [String: Any] {
    feature["geometry"] as? [String: Any] ?? [:]
}

@main
enum VerifyGeoImport {
    static func main() {
        do {
            try run()
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
        if failures > 0 {
            fputs("\(failures) failure(s)\n", stderr)
            exit(1)
        }
        print("ok: KML, KMZ, GPX converters and the GeoJSON render hand-off")
    }
}

func run() throws {
    let kml = try load("sample.kml")
    let gpx = try load("sample.gpx")
    let kmz = try load("sample.kmz")

    guard let kmlJSON = geoJSONData(from: kml, kind: .kml),
          let kmlFeatures = featureList(in: kmlJSON) else {
        fail("sample.kml did not convert")
        return
    }
    try checkKML(kmlFeatures, source: kmlJSON)

    check(kmz.count > 30 && kmz[0] == 0x50 && kmz[1] == 0x4b, "sample.kmz is not a zip")
    let methods = zipMethods(kmz)
    check(!methods.isEmpty && methods.allSatisfy { $0 == 8 },
          "sample.kmz entries should be deflate, methods \(methods)")

    guard let kmzJSON = geoJSONData(from: kmz, kind: .kmz),
          let kmzFeatures = featureList(in: kmzJSON) else {
        fail("sample.kmz did not convert")
        return
    }
    check(canon(kmzFeatures) == canon(kmlFeatures), "deflated doc.kml did not match sample.kml")

    guard let gpxJSON = geoJSONData(from: gpx, kind: .gpx),
          let gpxFeatures = featureList(in: gpxJSON) else {
        fail("sample.gpx did not convert")
        return
    }
    checkGPX(gpxFeatures, source: gpxJSON)

    checkEmptyAndMalformed()
    checkZipSelection()
    checkCDATA()
    checkExtendedDataName()
    checkSinglePointGPX()
    checkLargeKML()
    try checkRenderHandoff(kml: kml, gpx: gpx, kmz: kmz)
}

func checkKML(_ features: [[String: Any]], source: Data) throws {
    let names = features.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
    check(names == [
        "Park", "Mixed", "Gates", "Solo", "Paths", "Plots",
        "Block", "Loop", "Road", "Flight", "Flights"
    ], "KML feature names \(names)")
    for absent in ["Places", "Sample", "Should Not Appear", "Remote", "Overlay", "Styled"] {
        check(!names.contains(absent), "\(absent) should not be a feature")
    }

    let park = feature(features, "Park")!
    check(canon(park["properties"]!) == canon([
        "code": "P1",
        "description": "A & B",
        "name": "Park",
        "year": "2020"
    ]), "Park properties \(canon(park["properties"]!))")
    check(geometry(park)["type"] as? String == "Point", "Park type")
    check(canon(geometry(park)["coordinates"]!) == canon([-122.4, 37.8, 10.0]),
          "Park coordinates \(canon(geometry(park)["coordinates"]!))")

    let mixed = feature(features, "Mixed")!
    check(geometry(mixed)["type"] as? String == "GeometryCollection", "Mixed type")
    let parts = geometry(mixed)["geometries"] as? [[String: Any]] ?? []
    check(parts.count == 2
          && parts[0]["type"] as? String == "Point"
          && parts[1]["type"] as? String == "LineString",
          "Mixed geometries \(canon(parts))")

    let gates = feature(features, "Gates")!
    check(geometry(gates)["type"] as? String == "MultiPoint", "Gates type")
    check(canon(geometry(gates)["coordinates"]!) == canon([[-122.2, 37.2], [-122.3, 37.3, 5.0]]),
          "Gates coordinates \(canon(geometry(gates)["coordinates"]!))")

    let solo = feature(features, "Solo")!
    check(geometry(solo)["type"] as? String == "MultiPoint", "a one-member MultiGeometry stays Multi*")
    check(canon(geometry(solo)["coordinates"]!) == canon([[8.0, 8.0]]), "Solo coordinates")

    let paths = feature(features, "Paths")!
    check(geometry(paths)["type"] as? String == "MultiLineString", "Paths type")

    let plots = feature(features, "Plots")!
    check(geometry(plots)["type"] as? String == "MultiPolygon", "Plots type")
    check((geometry(plots)["coordinates"] as? [Any])?.count == 2, "Plots should have two polygons")

    let block = feature(features, "Block")!
    check(geometry(block)["type"] as? String == "Polygon", "Block type")
    check(canon(geometry(block)["coordinates"]!) == canon([
        [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]],
        [[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.8], [0.2, 0.2]]
    ]), "Block rings \(canon(geometry(block)["coordinates"]!))")

    let loop = feature(features, "Loop")!
    check(geometry(loop)["type"] as? String == "LineString", "LinearRing becomes a LineString")
    check(canon(geometry(loop)["coordinates"]!) == canon([[2.0, 2.0], [3.0, 2.0], [3.0, 3.0], [2.0, 2.0]]),
          "Loop coordinates")

    let road = feature(features, "Road")!
    check(geometry(road)["type"] as? String == "LineString", "Road type")
    check(canon(geometry(road)["coordinates"]!) == canon([[-121.0, 36.0, 1.0], [-121.5, 36.5, 2.0]]),
          "Road coordinates \(canon(geometry(road)["coordinates"]!))")

    let flight = feature(features, "Flight")!
    check(geometry(flight)["type"] as? String == "LineString", "gx:Track type")
    check(canon(geometry(flight)["coordinates"]!) == canon([[-120.0, 35.0, 100.0], [-120.1, 35.1, 110.0]]),
          "Flight coordinates")

    let flights = feature(features, "Flights")!
    check(geometry(flights)["type"] as? String == "MultiLineString", "gx:MultiTrack type")
    check((geometry(flights)["coordinates"] as? [Any])?.count == 2, "Flights should have two lines")

    guard let meta = parseGeoJSON(source) else {
        fail("converted KML was not GeoJSON")
        return
    }
    check(meta.featureCount == 11, "KML featureCount \(meta.featureCount)")
    check(meta.vertexCount == 43, "KML vertexCount \(meta.vertexCount)")
    check(meta.geometryTypes == [
        "LineString", "MultiLineString", "MultiPoint", "MultiPolygon", "Point", "Polygon"
    ], "KML geometry types \(meta.geometryTypes)")

    let openRing = """
    <kml><Placemark><name>Open</name><Polygon><outerBoundaryIs><LinearRing>
    <coordinates>0,0 1,0 1,1 0,1</coordinates>
    </LinearRing></outerBoundaryIs></Polygon></Placemark></kml>
    """
    guard let opened = geoJSONData(from: Data(openRing.utf8), kind: .kml),
          let openedFeatures = featureList(in: opened),
          openedFeatures.count == 1 else {
        fail("unclosed ring did not convert")
        return
    }
    let ring = geometry(openedFeatures[0])["coordinates"] ?? "missing"
    check(canon(ring) == canon([
        [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]
    ]), "unclosed ring was not closed: \(canon(ring))")
}

func checkGPX(_ features: [[String: Any]], source: Data) {
    let names = features.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
    check(names == ["Trailhead", "Bare", "Ridge", "Out", "Morning"], "GPX feature names \(names)")
    check(!names.contains("Ignored container"), "metadata name became a feature")

    let trail = feature(features, "Trailhead")!
    check(geometry(trail)["type"] as? String == "Point", "Trailhead type")
    check(canon(geometry(trail)["coordinates"]!) == canon([-122.4, 37.8, 12.5]),
          "Trailhead coordinates \(canon(geometry(trail)["coordinates"]!))")
    check(canon(trail["properties"]!) == canon([
        "desc": "Start & go",
        "ele": 12.5,
        "name": "Trailhead",
        "time": "2020-01-01T00:00:00Z",
        "type": "parking"
    ] as [String: Any]), "Trailhead properties \(canon(trail["properties"]!))")

    let bare = feature(features, "Bare")!
    check(canon(geometry(bare)["coordinates"]!) == canon([2.0, 1.0]), "Bare coordinates")
    check(canon(bare["properties"]!) == canon(["name": "Bare"]), "Bare properties")

    let ridge = feature(features, "Ridge")!
    check(geometry(ridge)["type"] as? String == "LineString", "Ridge type")
    check(canon(geometry(ridge)["coordinates"]!) == canon([
        [-122.4, 37.8, 12.5],
        [-122.5, 37.9, 20.0]
    ]), "Ridge coordinates \(canon(geometry(ridge)["coordinates"]!))")
    check(canon(ridge["properties"]!) == canon([
        "desc": "The ridge route",
        "name": "Ridge",
        "type": "route"
    ]), "Ridge properties should not copy per-point time \(canon(ridge["properties"]!))")

    let out = feature(features, "Out")!
    check(geometry(out)["type"] as? String == "LineString", "one trkseg is a LineString")
    check(canon(geometry(out)["coordinates"]!) == canon([[-122.1, 37.1, 1.0], [-122.2, 37.2, 2.0]]),
          "Out coordinates")

    let morning = feature(features, "Morning")!
    check(geometry(morning)["type"] as? String == "MultiLineString", "two trkseg values are a MultiLineString")
    check((geometry(morning)["coordinates"] as? [Any])?.count == 2, "Morning segment count")

    guard let meta = parseGeoJSON(source) else {
        fail("converted GPX was not GeoJSON")
        return
    }
    check(meta.featureCount == 5, "GPX featureCount \(meta.featureCount)")
    check(meta.vertexCount == 10, "GPX vertexCount \(meta.vertexCount)")
    check(meta.geometryTypes == ["LineString", "MultiLineString", "Point"],
          "GPX geometry types \(meta.geometryTypes)")

    let onePoint = """
    <gpx><rte><name>Short</name><rtept lat="1" lon="2"/></rte></gpx>
    """
    guard let shortJSON = geoJSONData(from: Data(onePoint.utf8), kind: .gpx),
          let short = featureList(in: shortJSON), short.count == 1 else {
        fail("a one-point route was dropped")
        return
    }
    check(geometry(short[0])["type"] as? String == "Point", "a one-point route should be a Point")
    check(geometry(short[0])["coordinates"] as? [Double] == [2, 1],
          "one-point route coordinates \(String(describing: geometry(short[0])["coordinates"]))")
    check((short[0]["properties"] as? [String: Any])?["name"] as? String == "Short",
          "one-point route lost its name")
}

func checkCDATA() {
    let kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
    <Document>
    <Placemark>
      <name><![CDATA[Ankara & Çankaya]]></name>
      <description><![CDATA[<b>bold</b> açıklama]]></description>
      <LineString><coordinates>
        32.85,39.92,850
        32.86 , 39.93 , 860
        32.87,39.94,870,
      </coordinates></LineString>
    </Placemark>
    <Placemark>
      <name>Partial CDATA <![CDATA[tail]]></name>
      <Point><coordinates>32.8,39.9</coordinates></Point>
    </Placemark>
    <Placemark>
      <description><![CDATA[

             Here is some text
      ]]></description>
      <Point><coordinates>-122.0822035425683,37.42228990140251,0</coordinates></Point>
    </Placemark>
    </Document>
    </kml>
    """
    guard let features = importedFeatures(Data(kml.utf8), .kml) else {
        fail("CDATA KML did not convert")
        return
    }
    check(features.count == 3, "CDATA KML feature count \(features.count)")
    let ankara = features[0]
    check((ankara["properties"] as? [String: Any])?["name"] as? String == "Ankara & Çankaya",
          "CDATA KML name \(String(describing: (ankara["properties"] as? [String: Any])?["name"]))")
    check((ankara["properties"] as? [String: Any])?["description"] as? String == "<b>bold</b> açıklama",
          "CDATA KML description was dropped or altered")
    check(geometry(ankara)["type"] as? String == "LineString", "CDATA KML line was not a LineString")
    let line = geometry(ankara)["coordinates"] as? [[Double]] ?? []
    check(line.count == 3, "CDATA KML line length \(line.count)")
    check(line.first == [32.85, 39.92, 850] && line.last == [32.87, 39.94, 870],
          "CDATA KML coordinates \(line)")
    check((features[1]["properties"] as? [String: Any])?["name"] as? String == "Partial CDATA tail",
          "mixed CDATA name \(String(describing: (features[1]["properties"] as? [String: Any])?["name"]))")
    check((features[2]["properties"] as? [String: Any])?["description"] as? String == "Here is some text",
          "whitespace-wrapped CDATA description was dropped")

    let gpx = """
    <gpx>
      <wpt lat="1" lon="2"><desc><![CDATA[A & B]]></desc></wpt>
      <wpt lat="3" lon="4"><desc>Partial <![CDATA[tail]]></desc></wpt>
    </gpx>
    """
    guard let points = importedFeatures(Data(gpx.utf8), .gpx) else {
        fail("CDATA GPX did not convert")
        return
    }
    check((points[0]["properties"] as? [String: Any])?["desc"] as? String == "A & B",
          "CDATA GPX desc \(String(describing: (points[0]["properties"] as? [String: Any])?["desc"]))")
    check((points[1]["properties"] as? [String: Any])?["desc"] as? String == "Partial tail",
          "mixed CDATA GPX desc \(String(describing: (points[1]["properties"] as? [String: Any])?["desc"]))")
}

func checkExtendedDataName() {
    let kml = """
    <kml>
    <Placemark>
      <name>Place</name>
      <description>About</description>
      <ExtendedData>
        <Data name="name"><value>Other</value></Data>
        <Data name="description"><value>Else</value></Data>
        <Data name="year"><value>2020</value></Data>
        <SchemaData>
          <SimpleData name="name">Schema</SimpleData>
          <SimpleData name="code">P1</SimpleData>
        </SchemaData>
      </ExtendedData>
      <Point><coordinates>1,2</coordinates></Point>
    </Placemark>
    <Placemark>
      <ExtendedData>
        <Data name="name"><value>FromData</value></Data>
        <Data name="note"><value>kept</value></Data>
      </ExtendedData>
      <Point><coordinates>3,4</coordinates></Point>
    </Placemark>
    <Placemark>
      <ExtendedData><Data name="name"><value>Early</value></Data></ExtendedData>
      <name>Late</name>
      <Point><coordinates>5,6</coordinates></Point>
    </Placemark>
    </kml>
    """
    guard let features = importedFeatures(Data(kml.utf8), .kml), features.count == 3 else {
        fail("ExtendedData name collision did not convert")
        return
    }
    let first = features[0]["properties"] as? [String: Any] ?? [:]
    check(first["name"] as? String == "Place", "placemark name lost to ExtendedData: \(first["name"] ?? "")")
    check(first["description"] as? String == "About", "placemark description lost to ExtendedData")
    check(first["year"] as? String == "2020", "non-colliding ExtendedData year was dropped")
    check(first["code"] as? String == "P1", "non-colliding SimpleData code was dropped")
    let second = features[1]["properties"] as? [String: Any] ?? [:]
    check(second["name"] as? String == "FromData", "ExtendedData name was dropped when the placemark had none")
    check(second["note"] as? String == "kept", "ExtendedData note was dropped")
    let third = features[2]["properties"] as? [String: Any] ?? [:]
    check(third["name"] as? String == "Late", "a name after ExtendedData did not win: \(third["name"] ?? "")")
}

func checkSinglePointGPX() {
    let only = """
    <gpx><trk><trkseg>
      <trkpt lat="-14.8547633" lon="-74.9606255"><ele>559.5</ele></trkpt>
    </trkseg></trk></gpx>
    """
    guard let one = importedFeatures(Data(only.utf8), .gpx), one.count == 1 else {
        fail("a one-point track was dropped")
        return
    }
    check(geometry(one[0])["type"] as? String == "Point", "one-point track should be a Point")
    check(geometry(one[0])["coordinates"] as? [Double] == [-74.9606255, -14.8547633, 559.5],
          "one-point track coordinates \(String(describing: geometry(one[0])["coordinates"]))")

    let many = """
    <gpx><trk><name>Dots</name>
      <trkseg><trkpt lat="1" lon="2"/></trkseg>
      <trkseg><trkpt lat="3" lon="4"/></trkseg>
    </trk></gpx>
    """
    guard let dots = importedFeatures(Data(many.utf8), .gpx), dots.count == 1 else {
        fail("a track of one-point segments was dropped")
        return
    }
    check(geometry(dots[0])["type"] as? String == "MultiPoint", "one-point segments should be a MultiPoint")
    check(geometry(dots[0])["coordinates"] as? [[Double]] == [[2, 1], [4, 3]],
          "MultiPoint coordinates \(String(describing: geometry(dots[0])["coordinates"]))")
    check((dots[0]["properties"] as? [String: Any])?["name"] as? String == "Dots",
          "one-point track lost its name")

    let mixed = """
    <gpx><trk><name>Keep</name>
      <trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg>
      <trkseg><trkpt lat="5" lon="6"/></trkseg>
    </trk></gpx>
    """
    guard let line = importedFeatures(Data(mixed.utf8), .gpx), line.count == 1 else {
        fail("a track with one real segment was dropped")
        return
    }
    check(geometry(line[0])["type"] as? String == "LineString", "a valid segment should stay a LineString")
    check(geometry(line[0])["coordinates"] as? [[Double]] == [[2, 1], [4, 3]],
          "the one-point segment was kept on the line")

    check(geoJSONData(from: Data("<gpx><trk><name>Empty</name><trkseg></trkseg></trk></gpx>".utf8), kind: .gpx) == nil,
          "an empty track was imported")
}

func checkLargeKML() {
    var data = Data("<?xml version=\"1.0\"?><kml><Document>".utf8)
    let pad = Data(repeating: 0x20, count: 100_000)
    for index in 0..<120 {
        data.append(Data("<Placemark><name>P\(index)</name><description>".utf8))
        data.append(pad)
        data.append(Data("</description><Point><coordinates>1,2</coordinates></Point></Placemark>".utf8))
    }
    data.append(Data("<Placemark><name>Tail</name><Point><coordinates>9,8</coordinates></Point></Placemark></Document></kml>".utf8))
    check(data.count > 10 * 1024 * 1024, "generated KML is only \(data.count) bytes")
    guard let features = importedFeatures(data, .kml) else {
        fail("KML over 10 MB did not parse")
        return
    }
    check(features.count == 121, "large KML feature count \(features.count)")
    let names = features.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
    check(names.first == "P0" && names.last == "Tail",
          "large KML did not keep the first and last placemark")
    check(geometry(features[120])["coordinates"] as? [Double] == [9, 8], "large KML tail coordinates were wrong")
}

func importedFeatures(_ data: Data, _ kind: GeoImportKind) -> [[String: Any]]? {
    guard let json = geoJSONData(from: data, kind: kind) else { return nil }
    return featureList(in: json)
}

func checkEmptyAndMalformed() {
    let emptyKML = "<?xml version=\"1.0\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document/></kml>"
    check(geoJSONData(from: Data(), kind: .kml) == nil, "empty KML converted")
    check(geoJSONData(from: Data(emptyKML.utf8), kind: .kml) == nil, "KML with no placemarks converted")
    check(geoJSONData(from: Data("<kml><Placemark></kml>".utf8), kind: .kml) == nil, "truncated KML converted")
    check(geoJSONData(from: Data("not a zip".utf8), kind: .kmz) == nil, "plain text converted as KMZ")
    check(geoJSONData(from: Data("<gpx></gpx>".utf8), kind: .gpx) == nil, "empty GPX converted")
    check(geoJSONData(from: Data("<gpx".utf8), kind: .gpx) == nil, "truncated GPX converted")

    checkNotValid(Data(), "empty.kml", "KML")
    checkNotValid(Data("<kml></Placemark>".utf8), "broken.kml", "KML")
    checkNotValid(Data("not a zip".utf8), "notes.kmz", "KMZ")
    checkNotValid(Data(), "empty.gpx", "GPX")
    check(makeErrorHTML().contains("Not Valid GeoJSON"), "the GeoJSON error page lost its format name")
    check(makeErrorHTML().contains("recognisable GeoJSON"), "the GeoJSON error page lost its sentence")
}

func checkNotValid(_ data: Data, _ fileName: String, _ format: String) {
    guard case .invalid(let html) = renderFilePreview(data: data, fileName: fileName) else {
        fail("\(fileName) did not show the Not Valid page")
        return
    }
    check(html.contains("Not Valid \(format)"), "\(fileName) is missing Not Valid \(format)")
    check(html.contains("recognisable \(format) data"), "\(fileName) is missing the format sentence")
    check(!html.contains("<script"), "\(fileName) error page has a script")
}

func checkZipSelection() {
    let doc = Data("<?xml version=\"1.0\"?><kml><Placemark><name>Document</name><Point><coordinates>1,2</coordinates></Point></Placemark></kml>".utf8)
    let other = Data("<?xml version=\"1.0\"?><kml><Placemark><name>Other</name><Point><coordinates>3,4</coordinates></Point></Placemark></kml>".utf8)
    let nested = Data("<?xml version=\"1.0\"?><kml><Placemark><name>Nested</name><Point><coordinates>5,6</coordinates></Point></Placemark></kml>".utf8)

    let preferred = storedZip([("other.kml", other), ("files/nested.kml", nested), ("doc.kml", doc)])
    check(featureName(in: preferred) == "Document", "doc.kml should win over an earlier root kml")

    let firstRoot = storedZip([("b.kml", other), ("a.kml", doc), ("dir/c.kml", nested)])
    check(featureName(in: firstRoot) == "Other", "without doc.kml the first root kml is used")

    let onlyNested = storedZip([("files/inside.kml", nested)])
    check(geoJSONData(from: onlyNested, kind: .kmz) == nil, "a nested kml is not a root document")
}

func featureName(in kmz: Data) -> String? {
    guard let data = geoJSONData(from: kmz, kind: .kmz),
          let list = featureList(in: data),
          let properties = list.first?["properties"] as? [String: Any] else { return nil }
    return properties["name"] as? String
}

func checkRenderHandoff(kml: Data, gpx: Data, kmz: Data) throws {
    switch renderFilePreview(data: kml, fileName: "sample.kml") {
    case .map(let html, let script):
        check(html.contains("maplibregl"), "KML map page is missing MapLibre")
        check(!html.contains("Not Valid"), "KML map page shows an error")
        check(!script.contains("<"), "KML user script is not base64-only: \(script.prefix(80))")
        guard let decoded = geoJSON(fromUserScript: script), let meta = parseGeoJSON(decoded) else {
            fail("KML user script did not decode to GeoJSON")
            return
        }
        check(meta.featureCount == 11, "rendered KML featureCount \(meta.featureCount)")
    case .fallback, .invalid:
        fail("sample.kml used the fallback page")
    }

    switch renderFilePreview(data: kmz, fileName: "sample.KMZ") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script), let meta = parseGeoJSON(decoded) else {
            fail("KMZ user script did not decode to GeoJSON")
            return
        }
        check(meta.featureCount == 11, "rendered KMZ featureCount \(meta.featureCount)")
    case .fallback, .invalid:
        fail("sample.KMZ used the fallback page")
    }

    switch renderFilePreview(data: gpx, fileName: "sample.gpx") {
    case .map:
        break
    case .fallback, .invalid:
        fail("sample.gpx used the fallback page")
    }

    let hostile = """
    <kml><Placemark><name>Bad</name><description><![CDATA[</script><script>alert(1)</script>]]></description>
    <Point><coordinates>1,2</coordinates></Point></Placemark></kml>
    """
    switch renderFilePreview(data: Data(hostile.utf8), fileName: "hostile.kml") {
    case .map(let html, let script):
        check(!html.contains("alert(1)"), "hostile KML description reached the map HTML")
        check(!script.contains("alert(1)") && !script.contains("<"), "hostile KML description broke the user script")
    case .fallback, .invalid:
        fail("hostile.kml did not render")
    }

    let point = try load("point.json")
    switch renderFilePreview(data: point, fileName: "point.json") {
    case .map(let html, _):
        check(html.contains("maplibregl"), "point.json no longer renders the map")
        check(!html.contains("Not Valid KML") && !html.contains("Not valid JSON"),
              "point.json was reported invalid")
    case .fallback, .invalid:
        fail("point.json used the fallback page")
    }

    let invalid = try load("invalid.json")
    switch renderFilePreview(data: invalid, fileName: "invalid.json") {
    case .fallback(let html):
        check(html.contains("Not valid JSON."), "invalid.json lost the JSON parse line")
        check(!html.contains("Not Valid KML") && !html.contains("Not Valid GeoJSON"),
              "invalid.json used the format error card")
    case .map, .invalid:
        fail("invalid.json rendered a map or the format error card")
    }

    switch renderFilePreview(data: point, fileName: "point.kml") {
    case .invalid(let html):
        check(html.contains("Not Valid KML"), "GeoJSON bytes named .kml should fail as KML")
    case .map, .fallback:
        fail("point.kml was parsed as GeoJSON")
    }
}

func geoJSON(fromUserScript script: String) -> Data? {
    guard let open = script.range(of: "window.__GEO__=\""), script.hasSuffix("\";") else { return nil }
    let literal = script[open.upperBound..<script.index(script.endIndex, offsetBy: -2)]
    return Data(base64Encoded: String(literal))
}

/// Compression method of each central-directory entry. 8 is deflate.
func zipMethods(_ data: Data) -> [UInt16] {
    guard let eocd = eocdOffset(data),
          let count = readU16(data, eocd + 10),
          let offset = readU32(data, eocd + 16) else { return [] }
    var cursor = Int(offset)
    var methods: [UInt16] = []
    for _ in 0..<Int(count) {
        guard readU32(data, cursor) == 0x02014b50,
              let method = readU16(data, cursor + 10),
              let nameLength = readU16(data, cursor + 28),
              let extraLength = readU16(data, cursor + 30),
              let commentLength = readU16(data, cursor + 32) else { return methods }
        methods.append(method)
        cursor += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
    }
    return methods
}

func eocdOffset(_ data: Data) -> Int? {
    guard data.count >= 22 else { return nil }
    var offset = data.count - 22
    let earliest = data.count - min(data.count, 22 + 65535)
    while offset >= earliest {
        if readU32(data, offset) == 0x06054b50,
           let commentLength = readU16(data, offset + 20),
           offset + 22 + Int(commentLength) == data.count {
            return offset
        }
        if offset == 0 { break }
        offset -= 1
    }
    return nil
}

func readU16(_ data: Data, _ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readU32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

func storedZip(_ files: [(String, Data)]) -> Data {
    var local = Data()
    var central = Data()
    for (name, body) in files {
        let nameData = Data(name.utf8)
        let offset = UInt32(local.count)
        local.append(le32(0x04034b50))
        local.append(le16(20))
        local.append(le16(0))
        local.append(le16(0))
        local.append(le16(0))
        local.append(le16(0))
        local.append(le32(0))
        local.append(le32(UInt32(body.count)))
        local.append(le32(UInt32(body.count)))
        local.append(le16(UInt16(nameData.count)))
        local.append(le16(0))
        local.append(nameData)
        local.append(body)

        central.append(le32(0x02014b50))
        central.append(le16(20))
        central.append(le16(20))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le32(0))
        central.append(le32(UInt32(body.count)))
        central.append(le32(UInt32(body.count)))
        central.append(le16(UInt16(nameData.count)))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le32(0))
        central.append(le32(offset))
        central.append(nameData)
    }
    var archive = local
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.append(le32(0x06054b50))
    archive.append(le16(0))
    archive.append(le16(0))
    archive.append(le16(UInt16(files.count)))
    archive.append(le16(UInt16(files.count)))
    archive.append(le32(UInt32(central.count)))
    archive.append(le32(centralOffset))
    archive.append(le16(0))
    return archive
}

func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xff), UInt8(value >> 8)])
}

func le32(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff)
    ])
}
