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
//
// nonfinite.gpx and nonfinite.kml carry NaN, infinity, a latitude of 95,
// longitude 181, longitude 540, and longitude 99999. latitude-95.geojson
// repeats the latitude and the two longitudes.
// with-image.kmz is doc.kml plus a PNG. zip-bomb.kmz points 32 central-directory
// entries at one deflate stream of 2_000_000 zero bytes (about 64 MB if every
// entry were inflated) and is a few kilobytes on disk. lying-size.kmz declares
// doc.kml shorter than its deflate stream.

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
    checkPropertyOrder(kml: kmlJSON, gpx: gpxJSON)

    checkEmptyAndMalformed()
    checkZipSelection()
    checkNothingToPreview()
    checkCDATA()
    checkExtendedDataName()
    checkSinglePointGPX()
    try checkNonFiniteCoordinates()
    try checkKMZInflate()
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

func checkPropertyOrder(kml: Data, gpx: Data) {
    let kmlKeys = propertyKeyOrders(in: kml)
    check(kmlKeys.first == ["name", "description", "year", "code"],
          "Park property order \(kmlKeys.first ?? [])")

    let extendedFirst = """
    <kml><Placemark>
      <ExtendedData>
        <Data name="rank"><value>1</value></Data>
        <Data name="cc"><value>qa</value></Data>
        <Data name="data"><value>87600</value></Data>
      </ExtendedData>
      <name>Qatar</name>
      <description>State</description>
      <Point><coordinates>51.5,25.3</coordinates></Point>
    </Placemark></kml>
    """
    guard let extended = geoJSONData(from: Data(extendedFirst.utf8), kind: .kml) else {
        fail("ExtendedData-before-name KML did not convert")
        return
    }
    check(propertyKeyOrders(in: extended) == [["name", "description", "rank", "cc", "data"]],
          "KML keys should be name, description, then ExtendedData order \(propertyKeyOrders(in: extended))")

    let gpxKeys = propertyKeyOrders(in: gpx)
    check(gpxKeys.first == ["ele", "time", "name", "desc", "type"],
          "Trailhead property order \(gpxKeys.first ?? [])")
    check(gpxKeys.count > 2 && gpxKeys[2] == ["name", "desc", "type"],
          "Ridge property order \(gpxKeys.count > 2 ? gpxKeys[2] : [])")

    let descFirst = """
    <gpx><wpt lat="1" lon="2"><desc>First</desc><name>Second</name><type>Third</type></wpt></gpx>
    """
    guard let swapped = geoJSONData(from: Data(descFirst.utf8), kind: .gpx) else {
        fail("GPX with desc before name did not convert")
        return
    }
    check(propertyKeyOrders(in: swapped) == [["desc", "name", "type"]],
          "GPX keys should follow element order \(propertyKeyOrders(in: swapped))")

    let geo = #"{"type":"Feature","properties":{"z":1,"a":2,"m":3},"geometry":{"type":"Point","coordinates":[1,2]}}"#
    switch renderFilePreview(data: Data(geo.utf8), fileName: "order.geojson") {
    case .map(_, let script):
        check(geoJSON(fromUserScript: script) == Data(geo.utf8),
              "a .geojson file's property key order was rewritten")
    case .fallback, .invalid, .nothingToPreview:
        fail("order.geojson did not render")
    }
}

/// Property-key order of each feature, read from the JSON text.
/// `JSONSerialization` dictionaries do not keep it.
func propertyKeyOrders(in data: Data) -> [[String]] {
    let text = String(decoding: data, as: UTF8.self)
    var index = text.startIndex
    var orders: [[String]] = []

    func skipSpace() {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
    }
    func peek() -> Character? { index < text.endIndex ? text[index] : nil }
    func eat(_ character: Character) -> Bool {
        skipSpace()
        guard peek() == character else { return false }
        index = text.index(after: index)
        return true
    }
    @discardableResult
    func skipString() -> Bool {
        guard peek() == "\"" else { return false }
        index = text.index(after: index)
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\\" {
                guard index < text.endIndex else { return false }
                index = text.index(after: index)
                continue
            }
            if character == "\"" { return true }
        }
        return false
    }
    func readString() -> String? {
        let start = index
        guard skipString(),
              let raw = String(text[start..<index]).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else {
            return nil
        }
        return value
    }
    func skipValue() -> Bool {
        skipSpace()
        guard let character = peek() else { return false }
        if character == "\"" { return skipString() }
        if character == "{" { return skipContainer("{", "}") }
        if character == "[" { return skipContainer("[", "]") }
        while index < text.endIndex {
            let next = text[index]
            if next == "," || next == "}" || next == "]" || next.isWhitespace { return true }
            index = text.index(after: index)
        }
        return false
    }
    func skipContainer(_ open: Character, _ close: Character) -> Bool {
        guard eat(open) else { return false }
        skipSpace()
        if eat(close) { return true }
        while true {
            guard skipValue() else { return false }
            skipSpace()
            if eat(close) { return true }
            guard eat(",") else { return false }
        }
    }
    func objectKeys() -> [String]? {
        guard eat("{") else { return nil }
        skipSpace()
        if eat("}") { return [] }
        var keys: [String] = []
        while true {
            skipSpace()
            guard let key = readString(), eat(":"), skipValue() else { return nil }
            keys.append(key)
            skipSpace()
            if eat("}") { return keys }
            guard eat(",") else { return nil }
        }
    }

    while index < text.endIndex {
        if peek() == "\"" {
            let start = index
            guard skipString() else { break }
            if text[start..<index] == "\"properties\"", eat(":"), let keys = objectKeys() {
                orders.append(keys)
            }
            continue
        }
        index = text.index(after: index)
    }
    return orders
}

func checkNonFiniteCoordinates() throws {
    let gpx = try load("nonfinite.gpx")
    guard let gpxFeatures = importedFeatures(gpx, .gpx) else {
        fail("nonfinite.gpx did not convert")
        return
    }
    let gpxNames = gpxFeatures.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
    check(gpxNames == ["NoEle", "Good", "Wide", "Limit", "Road", "Ridge"], "nonfinite GPX names \(gpxNames)")
    for absent in ["Bad", "High", "Far"] {
        check(!gpxNames.contains(absent), "\(absent) should have been dropped")
    }
    guard let wideGPX = namedFeature(gpxFeatures, "Wide"),
          let noEle = namedFeature(gpxFeatures, "NoEle"),
          let good = namedFeature(gpxFeatures, "Good"),
          let road = namedFeature(gpxFeatures, "Road"),
          let ridge = namedFeature(gpxFeatures, "Ridge") else { return }
    check(geometry(wideGPX)["coordinates"] as? [Double] == [181, 10], "longitude 181 was dropped")
    check(geometry(noEle)["coordinates"] as? [Double] == [-122.4, 37.8],
          "NaN elevation should leave the position without altitude \(String(describing: geometry(noEle)["coordinates"]))")
    let noEleProps = noEle["properties"] as? [String: Any] ?? [:]
    check(noEleProps["ele"] == nil, "NaN elevation was kept as a property")
    check(noEleProps["name"] as? String == "NoEle", "NoEle lost its name")
    guard let goodCoordinates = geometry(good)["coordinates"] else {
        fail("Good has no coordinates")
        return
    }
    check(canon(goodCoordinates) == canon([2.0, 1.0, 12.5]),
          "finite elevation was dropped \(canon(goodCoordinates))")
    check((good["properties"] as? [String: Any])?["ele"] as? Double == 12.5, "Good elevation property")
    check(geometry(road)["type"] as? String == "LineString", "route with a dropped point should stay a line")
    guard let roadCoordinates = geometry(road)["coordinates"],
          let ridgeCoordinates = geometry(ridge)["coordinates"] else {
        fail("Road or Ridge has no coordinates")
        return
    }
    check(canon(roadCoordinates) == canon([[20.0, 10.0], [21.0, 11.0]]),
          "Road kept the nan point \(canon(roadCoordinates))")
    check(canon(ridgeCoordinates) == canon([[5.0, 4.0, 1.0], [7.0, 6.0, 2.0]]),
          "Ridge kept the infinite point \(canon(ridgeCoordinates))")

    switch renderFilePreview(data: gpx, fileName: "nonfinite.gpx") {
    case .map:
        break
    case .fallback, .invalid, .nothingToPreview:
        fail("nonfinite.gpx should render the positions that remain")
    }

    let onlyBad = Data("<gpx><wpt lat=\"nan\" lon=\"inf\"><ele>NaN</ele><name>Gone</name></wpt></gpx>".utf8)
    check(geoJSONData(from: onlyBad, kind: .gpx) == nil, "a GPX with no finite position converted")
    checkNotValid(onlyBad, "bad.gpx", "GPX")

    let edge = Data("<gpx><wpt lat=\"90\" lon=\"-180\"><name>NW</name></wpt><wpt lat=\"-90\" lon=\"180\"><name>SE</name></wpt></gpx>".utf8)
    guard let edges = importedFeatures(edge, .gpx), edges.count == 2 else {
        fail("latitude 90 or longitude 180 was dropped")
        return
    }
    check(geometry(edges[0])["coordinates"] as? [Double] == [-180, 90], "NW edge coordinates")
    check(geometry(edges[1])["coordinates"] as? [Double] == [180, -90], "SE edge coordinates")

    let over = Data("<gpx><wpt lat=\"90.0001\" lon=\"0\"/><wpt lat=\"0\" lon=\"-180.0001\"><name>West</name></wpt><wpt lat=\"10\" lon=\"181\"><name>East</name></wpt><wpt lat=\"1\" lon=\"2\"><name>Inside</name></wpt></gpx>".utf8)
    guard let inside = importedFeatures(over, .gpx), inside.count == 3 else {
        fail("a longitude past 180 was dropped, or a latitude past 90 was kept")
        return
    }
    check((inside[0]["properties"] as? [String: Any])?["name"] as? String == "West", "West was dropped")
    let west = geometry(inside[0])["coordinates"] as? [Double] ?? []
    check(west.count == 2 && near(west[0], -180.0001) && near(west[1], 0), "West coordinates \(west)")
    check((inside[1]["properties"] as? [String: Any])?["name"] as? String == "East", "East was dropped")
    check(geometry(inside[1])["coordinates"] as? [Double] == [181, 10], "East coordinates")
    check((inside[2]["properties"] as? [String: Any])?["name"] as? String == "Inside", "the in-range waypoint was dropped")

    let textEle = Data("<gpx><wpt lat=\"1\" lon=\"2\"><ele>high</ele><name>Hill</name></wpt></gpx>".utf8)
    guard let hill = importedFeatures(textEle, .gpx), hill.count == 1 else {
        fail("a non-numeric elevation dropped the waypoint")
        return
    }
    check(geometry(hill[0])["coordinates"] as? [Double] == [2, 1], "non-numeric elevation was used as altitude")
    check((hill[0]["properties"] as? [String: Any])?["ele"] as? String == "high", "non-numeric elevation text was dropped")

    let kml = try load("nonfinite.kml")
    guard let kmlFeatures = importedFeatures(kml, .kml) else {
        fail("nonfinite.kml did not convert")
        return
    }
    let kmlNames = kmlFeatures.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
    check(kmlNames == ["Wide", "Limit", "Alt", "Line", "Track"], "nonfinite KML names \(kmlNames)")
    for absent in ["Huge", "Nan", "Inf", "High", "Far"] {
        check(!kmlNames.contains(absent), "\(absent) should have been dropped")
    }
    guard let wideKML = namedFeature(kmlFeatures, "Wide"),
          let limitKML = namedFeature(kmlFeatures, "Limit"),
          let alt = namedFeature(kmlFeatures, "Alt"),
          let line = namedFeature(kmlFeatures, "Line"),
          let track = namedFeature(kmlFeatures, "Track"),
          let altCoordinates = geometry(alt)["coordinates"],
          let lineCoordinates = geometry(line)["coordinates"],
          let trackCoordinates = geometry(track)["coordinates"] else { return }
    check(geometry(wideKML)["coordinates"] as? [Double] == [181, 10], "KML longitude 181 was dropped")
    check(geometry(limitKML)["coordinates"] as? [Double] == [540, 2], "KML longitude 540 was dropped")
    check(canon(altCoordinates) == canon([-122.4, 37.8]),
          "infinite altitude was kept \(canon(altCoordinates))")
    check(canon(lineCoordinates) == canon([[0.0, 0.0], [1.0, 1.0]]), "line kept a non-finite position")
    check(canon(trackCoordinates) == canon([[-120.0, 35.0, 100.0], [-120.1, 35.1]]),
          "track kept a non-finite position or altitude")

    let onlyHuge = Data("<kml><Placemark><name>Huge</name><Point><coordinates>1e999,1</coordinates></Point></Placemark></kml>".utf8)
    check(geoJSONData(from: onlyHuge, kind: .kml) == nil, "a KML with no finite position converted")
    checkNotValid(onlyHuge, "huge.kml", "KML")

    let geo = try load("latitude-95.geojson")
    guard let meta = parseGeoJSON(geo) else {
        fail("latitude-95.geojson did not parse")
        return
    }
    check(meta.featureCount == 4, "latitude-95 feature count \(meta.featureCount)")
    check(meta.vertexCount == 2, "latitude-95 vertex count \(meta.vertexCount)")
    if let bounds = meta.bounds {
        check(near(bounds.minLng, -122.4) && near(bounds.maxLng, 181)
              && near(bounds.minLat, 10) && near(bounds.maxLat, 37.8),
              "bounds \(bounds.minLng),\(bounds.minLat) \(bounds.maxLng),\(bounds.maxLat)")
    } else {
        fail("the in-range positions were left out of bounds")
    }
    let onlyHigh = Data(#"{"type":"Point","coordinates":[0,95]}"#.utf8)
    guard let highMeta = parseGeoJSON(onlyHigh) else {
        fail("a GeoJSON point at latitude 95 was rejected")
        return
    }
    check(highMeta.bounds == nil, "latitude 95 was used as the map bounds")
    check(highMeta.vertexCount == 0, "latitude 95 was counted")
    check(makeMapHTML(meta: highMeta).contains("\"bounds\":null"), "the map page kept an out-of-range bounds")
    let wide = Data(#"{"type":"Point","coordinates":[181,10]}"#.utf8)
    guard let wideMeta = parseGeoJSON(wide), let wideBounds = wideMeta.bounds else {
        fail("longitude 181 was left out of the map bounds")
        return
    }
    check(wideMeta.vertexCount == 1, "longitude 181 was not counted")
    check(near(wideBounds.minLng, 181) && near(wideBounds.maxLng, 181)
          && near(wideBounds.minLat, 10) && near(wideBounds.maxLat, 10),
          "longitude 181 bounds")
    let page = makeMapHTML(meta: wideMeta)
    check(page.contains("c[1] >= -90 && c[1] <= 90"), "featureBounds lost the latitude check")
    check(page.contains("Math.abs(c[0]) <= 540"), "featureBounds lost the longitude limit")
    check(page.contains("Array.isArray(c)"), "featureBounds does not guard its walk")
    check(!page.contains("c[0] >= -180") && !page.contains("c[0] <= 180"),
          "featureBounds still rejects a longitude past 180")
    try checkFeatureBoundsGuard(page)

    switch renderFilePreview(data: onlyHigh, fileName: "high.geojson") {
    case .map(_, let script):
        check(renderedFeatures(script)?.isEmpty == true, "latitude 95 was sent to the map")
    case .invalid, .fallback, .nothingToPreview:
        fail("filtering a point at latitude 95 made the file Not Valid")
    }
    let past = Data(#"{"type":"Point","coordinates":[540.1,1]}"#.utf8)
    switch renderFilePreview(data: past, fileName: "past.geojson") {
    case .map(_, let script):
        check(renderedFeatures(script)?.isEmpty == true, "longitude 540.1 was sent to the map")
    case .invalid, .fallback, .nothingToPreview:
        fail("filtering longitude 540.1 made the file Not Valid")
    }
    let emptyCollection = Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)
    switch renderFilePreview(data: emptyCollection, fileName: "empty.geojson") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script) else {
            fail("empty FeatureCollection was not sent to the map")
            return
        }
        check(decoded == emptyCollection, "empty FeatureCollection was rewritten")
    case .invalid, .fallback, .nothingToPreview:
        fail("an empty FeatureCollection was not opened")
    }
    let limit = Data(#"{"type":"Point","coordinates":[-540,1]}"#.utf8)
    switch renderFilePreview(data: limit, fileName: "limit.geojson") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script) else {
            fail("longitude -540 was rewritten or dropped")
            return
        }
        check(decoded == limit, "a drawable GeoJSON point was rewritten")
    case .fallback, .invalid, .nothingToPreview:
        fail("longitude -540 was not drawn")
    }

    switch renderFilePreview(data: geo, fileName: "latitude-95.geojson") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script),
              let drawn = featureList(in: decoded) else {
            fail("latitude-95.geojson was not sent to the map")
            return
        }
        let drawnNames = drawn.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
        check(drawnNames == ["High", "Wide", "Ok", "Far"], "map features \(drawnNames)")
        check(drawn.first?["geometry"] is NSNull, "High was removed instead of kept with null geometry")
        check(drawn.last?["geometry"] is NSNull, "Far was removed instead of kept with null geometry")
        guard let drawnMeta = parseGeoJSON(decoded) else {
            fail("sanitized GeoJSON did not parse")
            return
        }
        check(drawnMeta.featureCount == 4 && drawnMeta.vertexCount == 2, "sanitized counts")
        if let bounds = drawnMeta.bounds {
            check(near(bounds.minLng, -122.4) && near(bounds.maxLng, 181)
                  && near(bounds.minLat, 10) && near(bounds.maxLat, 37.8),
                  "sanitized bounds")
        } else {
            fail("sanitized GeoJSON lost its bounds")
        }
    case .fallback, .invalid, .nothingToPreview:
        fail("latitude-95.geojson was not drawn")
    }

    let mixed = Data(#"""
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"name":"Path"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,95],[99999,1],[540,2],[2,2]]}},
      {"type":"Feature","properties":{"name":"Gone"},"geometry":{"type":"Point","coordinates":[0,95]}},
      {"type":"Feature","properties":{"name":"Thin"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,95],[0,0]]]}},
      {"type":"Feature","properties":{"name":"Ring"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,95],[0,1],[0,0]]]}}
    ]}
    """#.utf8)
    switch renderFilePreview(data: mixed, fileName: "mixed.geojson") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script),
              let drawn = featureList(in: decoded) else {
            fail("mixed GeoJSON was not sent to the map")
            return
        }
        let drawnNames = drawn.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
        check(drawnNames == ["Path", "Gone", "Thin", "Ring"], "mixed map features \(drawnNames)")
        guard let path = namedFeature(drawn, "Path"),
              let gone = namedFeature(drawn, "Gone"),
              let thin = namedFeature(drawn, "Thin"),
              let ring = namedFeature(drawn, "Ring"),
              let pathCoordinates = geometry(path)["coordinates"],
              let ringCoordinates = geometry(ring)["coordinates"] else { return }
        check(canon(pathCoordinates) == canon([[0.0, 0.0], [540.0, 2.0], [2.0, 2.0]]),
              "Path kept a bad position")
        check(gone["geometry"] is NSNull, "Gone was removed instead of kept with null geometry")
        check(thin["geometry"] is NSNull, "Thin was removed instead of kept with null geometry")
        check(canon(ringCoordinates) == canon([
            [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0], [0.0, 0.0]]
        ]), "Ring kept a latitude of 95")
    case .fallback, .invalid, .nothingToPreview:
        fail("mixed GeoJSON was not drawn")
    }

    try checkNullGeometryPreservation()
    try checkRingReclose()
    try checkJSONBooleans()
    try checkKMLCoordinateScan()

    let script = try String(contentsOfFile: "Shared/maplibre-gl.js", encoding: .utf8)
    check(script.contains("\"5.24.1\""), "vendored MapLibre is not 5.24.1")
    check(!script.contains("5.24.0"), "vendored MapLibre still names 5.24.0")
}

/// Whitespace-separated junk, nan, and inf must not shift the next lon,lat.
/// A 2-component tuple and a 3-component tuple stay separate. A non-finite
/// altitude is omitted. A longitude of 200 is kept. A latitude of 95 is not.
func checkKMLCoordinateScan() throws {
    let text = """
    <?xml version="1.0"?>
    <kml><Placemark><name>Scan</name><LineString><coordinates>
    nan,5 inf,10 -inf,1
    1,2
    junk
    3,4,5
    foo 6,7
    8,9,nan
    10, 11, 12
    1e999,2
    200,45
    10,95
    abc,def
    13,14,15 16,17
    </coordinates></LineString></Placemark></kml>
    """
    guard let features = importedFeatures(Data(text.utf8), .kml), features.count == 1 else {
        fail("KML coordinate scan did not keep a line")
        return
    }
    let expected: [[Double]] = [
        [1, 2],
        [3, 4, 5],
        [6, 7],
        [8, 9],
        [10, 11, 12],
        [200, 45],
        [13, 14, 15],
        [16, 17]
    ]
    guard let scanned = geometry(features[0])["coordinates"] else {
        fail("KML coordinate scan kept no coordinates")
        return
    }
    check(canon(scanned) == canon(expected), "KML coordinates were misread \(canon(scanned))")
}

func checkFeatureBoundsGuard(_ html: String) throws {
    guard let start = html.range(of: "function featureBounds(f) {") else {
        fail("featureBounds missing")
        return
    }
    let rest = html[start.lowerBound...]
    guard let end = rest.range(of: "function buildTable") else {
        fail("featureBounds end missing")
        return
    }
    let function = String(rest[..<end.lowerBound])
    let program = """
    \(function)
    function LngLatBounds() {
      this.points = [];
      this.extend = function(p) { this.points.push(p); };
    }
    var maplibregl = { LngLatBounds: LngLatBounds };
    var bounds = featureBounds({ geometry: { coordinates: [null, true, [10, 20], [99999, 5], [0, 95], [540, 1], [-540, -90], [540.1, 1]] } });
    if (!bounds || bounds.points.length !== 3) throw new Error('flat ' + (bounds && bounds.points.length));
    var nested = featureBounds({ geometry: { coordinates: [[null, [1, 2]], [[181, 3], false]] } });
    if (!nested || nested.points.length !== 2) throw new Error('nested ' + (nested && nested.points.length));
    if (featureBounds({ geometry: { coordinates: [null, false] } }) !== null) throw new Error('empty');
    var collection = featureBounds({ geometry: { type: 'GeometryCollection', geometries: [
      { type: 'Point', coordinates: [4, 5] },
      { type: 'LineString', coordinates: [[6, 7], [true, false]] },
      { type: 'GeometryCollection', geometries: [{ type: 'Point', coordinates: [8, 9] }] }
    ] } });
    if (!collection || collection.points.length !== 3) throw new Error('collection ' + (collection && collection.points.length));
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("geopeek-feature-bounds.js")
    try program.write(to: url, atomically: true, encoding: .utf8)
    let node = Process()
    node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    node.arguments = ["node", url.path]
    let err = Pipe()
    node.standardError = err
    try node.run()
    node.waitUntilExit()
    let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(node.terminationStatus == 0, "featureBounds rejected a malformed coordinate: \(text)")
}

func namedFeature(_ features: [[String: Any]], _ name: String) -> [String: Any]? {
    guard let found = feature(features, name) else {
        fail("missing feature \(name)")
        return nil
    }
    return found
}

func renderedFeatures(_ script: String) -> [[String: Any]]? {
    guard let decoded = geoJSON(fromUserScript: script) else { return nil }
    if let features = featureList(in: decoded) { return features }
    guard let object = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
          object["type"] as? String == "FeatureCollection",
          let features = object["features"] as? [Any] else { return nil }
    return features.isEmpty ? [] : nil
}

func checkNullGeometryPreservation() throws {
    let file = try load("null-geometry.geojson")
    switch renderFilePreview(data: file, fileName: "null-geometry.geojson") {
    case .map(_, let script):
        guard let drawn = renderedFeatures(script) else {
            fail("null-geometry.geojson was not sent to the map")
            return
        }
        let names = drawn.compactMap { ($0["properties"] as? [String: Any])?["name"] as? String }
        check(names == ["Unlocated", "Place", "Bad"], "null-geometry features \(names)")
        guard let unlocated = namedFeature(drawn, "Unlocated"),
              let place = namedFeature(drawn, "Place"),
              let bad = namedFeature(drawn, "Bad") else { return }
        check(unlocated["geometry"] is NSNull, "a null geometry was removed")
        check((unlocated["properties"] as? [String: Any])?["note"] as? String == "kept",
              "Unlocated lost a property")
        check(geometry(place)["coordinates"] as? [Double] == [10, 20], "Place coordinates changed")
        check(bad["geometry"] is NSNull, "Bad was removed instead of kept with null geometry")
        check((bad["properties"] as? [String: Any])?["name"] as? String == "Bad", "Bad lost its name")
    case .invalid, .fallback, .nothingToPreview:
        fail("null-geometry.geojson was not opened")
    }
}

func checkRingReclose() throws {
    let file = try load("reclose-ring.geojson")
    switch renderFilePreview(data: file, fileName: "reclose-ring.geojson") {
    case .map(_, let script):
        guard let drawn = renderedFeatures(script),
              let reclosed = namedFeature(drawn, "Reclosed"),
              let short = namedFeature(drawn, "Short"),
              let coordinates = geometry(reclosed)["coordinates"] else { return }
        check(canon(coordinates) == canon([[[1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [1.0, 0.0]]]),
              "ring was not reclosed \(canon(coordinates))")
        check(short["geometry"] is NSNull, "a ring shorter than four positions was kept")
        check((short["properties"] as? [String: Any])?["name"] as? String == "Short", "Short lost its name")
    case .invalid, .fallback, .nothingToPreview:
        fail("reclose-ring.geojson was not opened")
    }
}

func checkJSONBooleans() throws {
    let file = Data(#"""
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"name":"Bool"},"geometry":{"type":"Point","coordinates":[true,false]}},
      {"type":"Feature","properties":{"name":"One"},"geometry":{"type":"Point","coordinates":[1,0]}}
    ]}
    """#.utf8)
    guard let meta = parseGeoJSON(file), let bounds = meta.bounds else {
        fail("a point at [1, 0] was not counted")
        return
    }
    check(meta.vertexCount == 1, "a JSON boolean was counted \(meta.vertexCount)")
    check(near(bounds.minLng, 1) && near(bounds.minLat, 0) && near(bounds.maxLng, 1) && near(bounds.maxLat, 0),
          "boolean coordinates were used as bounds")
    switch renderFilePreview(data: file, fileName: "bool.geojson") {
    case .map(_, let script):
        guard let drawn = renderedFeatures(script),
              let flag = namedFeature(drawn, "Bool"),
              let one = namedFeature(drawn, "One") else { return }
        check(flag["geometry"] is NSNull, "boolean coordinates were sent to the map")
        check(geometry(one)["coordinates"] as? [Double] == [1, 0], "the number 1 was treated as a boolean")
    case .invalid, .fallback, .nothingToPreview:
        fail("boolean coordinates made the file Not Valid")
    }
}

func near(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 1e-9
}

func checkKMZInflate() throws {
    let image = try load("with-image.kmz")
    let names = zipNames(image)
    check(names == ["doc.kml", "files/photo.png"] || (names.contains("doc.kml") && names.contains("files/photo.png")),
          "with-image.kmz entries \(names)")
    guard let photo = importedFeatures(image, .kmz), photo.count == 1 else {
        fail("with-image.kmz did not convert")
        return
    }
    check((photo[0]["properties"] as? [String: Any])?["name"] as? String == "Photo Stop",
          "with-image.kmz did not read doc.kml")
    check(canon(geometry(photo[0])["coordinates"]!) == canon([-122.4, 37.8, 12.0]),
          "with-image coordinates \(canon(geometry(photo[0])["coordinates"]!))")

    let lying = try load("lying-size.kmz")
    check(featureName(in: lying) == nil, "a KMZ whose KML expands past its declared size was read")
    checkNotValid(lying, "lying-size.kmz", "KMZ")

    let bomb = try load("zip-bomb.kmz")
    check(bomb.count < 32_000, "zip bomb is \(bomb.count) bytes on disk")
    let bombNames = zipNames(bomb)
    check(bombNames.contains("doc.kml") && bombNames.filter { $0.hasSuffix(".bin") }.count == 32,
          "zip bomb central directory \(bombNames)")
    let beforeKB = highWaterKB()
    check(featureName(in: bomb) == "Kept", "zip bomb did not read doc.kml")
    if let beforeKB, let afterKB = highWaterKB() {
        check(afterKB - beforeKB < 16_000,
              "zip bomb inflated \(afterKB - beforeKB) KB; only doc.kml should be unpacked")
    }
    guard let kept = importedFeatures(bomb, .kmz), kept.count == 1 else {
        fail("zip bomb doc.kml did not convert")
        return
    }
    check(geometry(kept[0])["coordinates"] as? [Double] == [9, 8], "zip bomb coordinates")

    let doc = Data("<?xml version=\"1.0\"?><kml><Placemark><name>Document</name><Point><coordinates>1,2</coordinates></Point></Placemark></kml>".utf8)
    let valid = storedZip([("doc.kml", doc)])
    check(featureName(in: valid) == "Document", "stored doc.kml with a matching CRC should be read")
    check(featureName(in: corruptCentralCRC(valid)) == nil, "a KMZ with a bad CRC was read")
}

/// Peak resident set, in kilobytes, where the platform reports it.
func highWaterKB() -> Int? {
    #if os(Linux)
    guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("VmHWM:") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, let value = Int(fields[1]) { return value }
    }
    return nil
    #else
    return nil
    #endif
}

func zipNames(_ data: Data) -> [String] {
    guard let eocd = eocdOffset(data),
          let count = readU16(data, eocd + 10),
          let offset = readU32(data, eocd + 16) else { return [] }
    var cursor = Int(offset)
    var names: [String] = []
    for _ in 0..<Int(count) {
        guard readU32(data, cursor) == 0x02014b50,
              let nameLength = readU16(data, cursor + 28),
              let extraLength = readU16(data, cursor + 30),
              let commentLength = readU16(data, cursor + 32),
              cursor + 46 + Int(nameLength) <= data.count else { return names }
        let start = cursor + 46
        let nameData = data.subdata(in: start..<(start + Int(nameLength)))
        names.append(String(decoding: nameData, as: UTF8.self))
        cursor = start + Int(nameLength) + Int(extraLength) + Int(commentLength)
    }
    return names
}

func corruptCentralCRC(_ archive: Data) -> Data {
    guard let eocd = eocdOffset(archive),
          let offset = readU32(archive, eocd + 16) else { return archive }
    let index = Int(offset) + 16
    guard index < archive.count else { return archive }
    var copy = archive
    copy[index] ^= 0xff
    return copy
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
    check(featureName(in: onlyNested) == "Nested", "a KMZ whose only kml is nested should be read")

    let nestedDoc = storedZip([
        ("files/other.kml", other),
        ("dir/sub/doc.kml", doc)
    ])
    check(featureName(in: nestedDoc) == "Document", "a nested doc.kml wins over an earlier nested kml")

    let firstNested = storedZip([
        ("files/a.kml", other),
        ("files/b.kml", doc)
    ])
    check(featureName(in: firstNested) == "Other", "without doc.kml the first nested kml is used")

    // A root kml still wins even when a nested doc.kml comes first in the archive.
    let rootWins = storedZip([
        ("files/doc.kml", doc),
        ("b.kml", other)
    ])
    check(featureName(in: rootWins) == "Other", "a root kml wins over a nested doc.kml")
}

func checkNothingToPreview() {
    let overlays = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
      <NetworkLink><Link><href>https://example.com/a.kml</href></Link></NetworkLink>
      <GroundOverlay><Icon><href>https://example.com/a.png</href></Icon></GroundOverlay>
      <ScreenOverlay><Icon><href>https://example.com/b.png</href></Icon></ScreenOverlay>
      <PhotoOverlay><Icon><href>https://example.com/c.png</href></Icon></PhotoOverlay>
    </Document></kml>
    """
    let bareLink = """
    <?xml version="1.0" encoding="UTF-8"?>
    <NetworkLink id="link"><Link><href>Level1/doc.kml</href></Link></NetworkLink>
    """
    let documentLink = """
    <?xml version="1.0"?><Document><NetworkLink><Link><href>https://example.com/a.kml</href></Link></NetworkLink></Document>
    """
    let mixed = """
    <?xml version="1.0"?><kml><Document>
      <Placemark><name>Pin</name><Point><coordinates>1,2</coordinates></Point></Placemark>
      <GroundOverlay><Icon><href>https://example.com/a.png</href></Icon></GroundOverlay>
      <NetworkLink><Link><href>https://example.com/a.kml</href></Link></NetworkLink>
    </Document></kml>
    """
    let styleOnly = """
    <?xml version="1.0"?><kml><Document><Style><IconStyle/></Style></Document></kml>
    """

    checkNothingPage(Data(overlays.utf8), "overlays.kml", "KML")
    checkNothingPage(Data(bareLink.utf8), "bare-link.kml", "KML")
    checkNothingPage(Data(documentLink.utf8), "document-link.kml", "KML")
    checkNothingPage(storedZip([("doc.kml", Data(overlays.utf8))]), "overlays.kmz", "KMZ")
    checkNothingPage(storedZip([("files/doc.kml", Data(overlays.utf8))]), "nested-overlays.kmz", "KMZ")

    let nestedPoint = Data("<?xml version=\"1.0\"?><kml><Placemark><name>Nested</name><Point><coordinates>5,6</coordinates></Point></Placemark></kml>".utf8)
    let rootLink = storedZip([
        ("doc.kml", Data(bareLink.utf8)),
        ("files/doc.kml", nestedPoint)
    ])
    checkNothingPage(rootLink, "root-link.kmz", "KMZ")
    check(featureName(in: rootLink) == nil, "a root NetworkLink should not fall through to a nested placemark")

    switch renderFilePreview(data: Data(mixed.utf8), fileName: "mixed.kml") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script),
              let list = featureList(in: decoded) else {
            fail("mixed kml did not decode")
            return
        }
        check(list.count == 1, "mixed kml feature count \(list.count)")
        check((list.first?["properties"] as? [String: Any])?["name"] as? String == "Pin",
              "mixed kml dropped the placemark")
    case .fallback, .invalid, .nothingToPreview:
        fail("mixed kml should render the map")
    }

    checkNotValid(Data(styleOnly.utf8), "style.kml", "KML")
    checkNotValid(Data("<notkml><NetworkLink/></notkml>".utf8), "foreign.kml", "KML")
    checkNotValid(Data("<kml><NetworkLink></kml>".utf8), "truncated-link.kml", "KML")
    checkNotValid(Data("<?xml version=\"1.0\"?><kml><Document/></kml>".utf8), "empty-doc.kml", "KML")
}

func checkNothingPage(_ data: Data, _ fileName: String, _ format: String) {
    guard case .nothingToPreview(let html) = renderFilePreview(data: data, fileName: fileName) else {
        fail("\(fileName) did not show Nothing to Preview")
        return
    }
    let body = "This \(format) file only contains network links or image overlays, which GeoPeek doesn't show yet."
    let other = format == "KML" ? "KMZ" : "KML"
    check(html.contains("Nothing to Preview"), "\(fileName) is missing the title")
    check(html.contains(body), "\(fileName) is missing the body")
    check(!html.contains("This \(other) file"), "\(fileName) uses the \(other) sentence")
    check(!html.contains("Not Valid"), "\(fileName) uses the Not Valid page")
    check(!html.contains("<script"), "\(fileName) page has a script")
    check(html.contains("class=\"card\""), "\(fileName) lost the status card")
    let kind: GeoImportKind = format == "KMZ" ? .kmz : .kml
    check(geoJSONData(from: data, kind: kind) == nil, "\(fileName) produced GeoJSON")
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
    case .fallback, .invalid, .nothingToPreview:
        fail("sample.kml used the fallback page")
    }

    switch renderFilePreview(data: kmz, fileName: "sample.KMZ") {
    case .map(_, let script):
        guard let decoded = geoJSON(fromUserScript: script), let meta = parseGeoJSON(decoded) else {
            fail("KMZ user script did not decode to GeoJSON")
            return
        }
        check(meta.featureCount == 11, "rendered KMZ featureCount \(meta.featureCount)")
    case .fallback, .invalid, .nothingToPreview:
        fail("sample.KMZ used the fallback page")
    }

    switch renderFilePreview(data: gpx, fileName: "sample.gpx") {
    case .map:
        break
    case .fallback, .invalid, .nothingToPreview:
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
    case .fallback, .invalid, .nothingToPreview:
        fail("hostile.kml did not render")
    }

    let point = try load("point.json")
    switch renderFilePreview(data: point, fileName: "point.json") {
    case .map(let html, _):
        check(html.contains("maplibregl"), "point.json no longer renders the map")
        check(!html.contains("Not Valid KML") && !html.contains("Not valid JSON"),
              "point.json was reported invalid")
    case .fallback, .invalid, .nothingToPreview:
        fail("point.json used the fallback page")
    }

    let invalid = try load("invalid.json")
    switch renderFilePreview(data: invalid, fileName: "invalid.json") {
    case .fallback(let html):
        check(html.contains("Not valid JSON."), "invalid.json lost the JSON parse line")
        check(!html.contains("Not Valid KML") && !html.contains("Not Valid GeoJSON"),
              "invalid.json used the format error card")
    case .map, .invalid, .nothingToPreview:
        fail("invalid.json rendered a map or the format error card")
    }

    switch renderFilePreview(data: point, fileName: "point.kml") {
    case .invalid(let html):
        check(html.contains("Not Valid KML"), "GeoJSON bytes named .kml should fail as KML")
    case .map, .fallback, .nothingToPreview:
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
        let crc = crc32(body)
        local.append(le32(0x04034b50))
        local.append(le16(20))
        local.append(le16(0))
        local.append(le16(0))
        local.append(le16(0))
        local.append(le16(0))
        local.append(le32(crc))
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
        central.append(le32(crc))
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

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
    }
    return crc ^ 0xFFFF_FFFF
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
