//
//  GeoJSONImport.swift
//  Shared — compiled into the app, the preview, and the thumbnail appex.
//
//  KML, KMZ, and GPX become a GeoJSON FeatureCollection. The map, table,
//  stats, and thumbnail paths then run unchanged.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(zlib)
import zlib
#endif

// MARK: - File kinds

enum GeoImportKind {
    case kml
    case kmz
    case gpx

    init?(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "kml": self = .kml
        case "kmz": self = .kmz
        case "gpx": self = .gpx
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .kml: return "KML"
        case .kmz: return "KMZ"
        case .gpx: return "GPX"
        }
    }
}

/// True for the files the app opens from Finder, the Open panel, drag and drop, and Recents.
func isSupportedDocument(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if ext == "geojson" || ext == "json" { return true }
    return GeoImportKind(fileName: url.lastPathComponent) != nil
}

/// FeatureCollection bytes, a valid KML/KMZ with nothing GeoPeek can draw, or not valid.
enum GeoImportResult {
    case geoJSON(Data)
    /// Parse succeeded, a KML root is present, there are no supported features,
    /// and the file has at least one NetworkLink or image overlay.
    case nothingToPreview
    case invalid
}

/// A FeatureCollection for `data`, or nil when the file is empty, not valid for `kind`,
/// or only contains network links and image overlays.
func geoJSONData(from data: Data, kind: GeoImportKind) -> Data? {
    guard case .geoJSON(let encoded) = importGeoData(data, kind: kind) else { return nil }
    return encoded
}

func importGeoData(_ data: Data, kind: GeoImportKind) -> GeoImportResult {
    switch kind {
    case .kml:
        return kmlImportResult(data)
    case .kmz:
        guard let kml = kmlDocument(in: data) else { return .invalid }
        return kmlImportResult(kml)
    case .gpx:
        guard let features = GPXConverter.features(in: data) else { return .invalid }
        return encodeFeatures(features)
    }
}

private func kmlImportResult(_ data: Data) -> GeoImportResult {
    switch KMLConverter.read(data) {
    case .features(let features):
        return encodeFeatures(features)
    case .nothingToPreview:
        return .nothingToPreview
    case .invalid:
        return .invalid
    }
}

private func encodeFeatures(_ features: [GJFeature]) -> GeoImportResult {
    guard !features.isEmpty else { return .invalid }
    var encoded: [String] = []
    encoded.reserveCapacity(features.count)
    for feature in features {
        guard let text = feature.jsonText() else { return .invalid }
        encoded.append(text)
    }
    let collection = "{\"type\":\"FeatureCollection\",\"features\":[\(encoded.joined(separator: ","))]}"
    return .geoJSON(Data(collection.utf8))
}

// MARK: - GeoJSON geometry

private enum GJGeometry {
    case point([Double])
    case multiPoint([[Double]])
    case lineString([[Double]])
    case multiLineString([[[Double]]])
    case polygon([[[Double]]])
    case multiPolygon([[[[Double]]]])
    case collection([GJGeometry])

    /// Singular Point, LineString, and Polygon values. Multi* and collections expand.
    func parts() -> [GJGeometry] {
        switch self {
        case .point, .lineString, .polygon:
            return [self]
        case .multiPoint(let coordinates):
            return coordinates.map { .point($0) }
        case .multiLineString(let lines):
            return lines.map { .lineString($0) }
        case .multiPolygon(let polygons):
            return polygons.map { .polygon($0) }
        case .collection(let geometries):
            return geometries.flatMap { $0.parts() }
        }
    }

    func jsonObject() -> [String: Any] {
        switch self {
        case .point(let coordinates):
            return ["type": "Point", "coordinates": coordinates]
        case .multiPoint(let coordinates):
            return ["type": "MultiPoint", "coordinates": coordinates]
        case .lineString(let coordinates):
            return ["type": "LineString", "coordinates": coordinates]
        case .multiLineString(let coordinates):
            return ["type": "MultiLineString", "coordinates": coordinates]
        case .polygon(let coordinates):
            return ["type": "Polygon", "coordinates": coordinates]
        case .multiPolygon(let coordinates):
            return ["type": "MultiPolygon", "coordinates": coordinates]
        case .collection(let geometries):
            return ["type": "GeometryCollection", "geometries": geometries.map { $0.jsonObject() }]
        }
    }
}

/// Property bag that remembers first-seen key order. `JSONSerialization` writes
/// a Swift dictionary in per-process hash order, so the app and Quick Look
/// would otherwise show the same file's columns differently.
private struct OrderedProperties {
    private var keys: [String] = []
    private var values: [String: Any] = [:]

    subscript(key: String) -> Any? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else {
                remove(key)
            }
        }
    }

    mutating func remove(_ key: String) {
        values.removeValue(forKey: key)
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) }
    }

    /// New keys append. A key that is already present keeps its place; the value updates.
    mutating func merge(_ other: OrderedProperties) {
        for key in other.keys {
            self[key] = other.values[key]
        }
    }

    /// Placemark `name` and `description` lead. ExtendedData keeps document order after them.
    mutating func pinNameAndDescription() {
        var ordered: [String] = []
        if values["name"] != nil { ordered.append("name") }
        if values["description"] != nil { ordered.append("description") }
        ordered.append(contentsOf: keys.filter { $0 != "name" && $0 != "description" })
        keys = ordered
    }

    func jsonText() -> String? {
        var parts: [String] = []
        parts.reserveCapacity(keys.count)
        for key in keys {
            guard let value = values[key],
                  let name = jsonScalar(key),
                  let encoded = jsonScalar(value) else { return nil }
            parts.append("\(name):\(encoded)")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}

private struct GJFeature {
    var geometry: GJGeometry
    var properties: OrderedProperties

    func jsonText() -> String? {
        guard let properties = properties.jsonText(),
              let geometry = jsonObjectText(geometry.jsonObject()) else { return nil }
        return "{\"type\":\"Feature\",\"properties\":\(properties),\"geometry\":\(geometry)}"
    }
}

private func featureObject(_ geometry: GJGeometry, _ properties: OrderedProperties) -> GJFeature {
    GJFeature(geometry: geometry, properties: properties)
}

/// One JSON value, without the array brackets `JSONSerialization` needs to accept a scalar.
private func jsonScalar(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let text = String(data: data, encoding: .utf8),
          text.first == "[", text.last == "]" else { return nil }
    return String(text.dropFirst().dropLast())
}

private func jsonObjectText(_ object: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return text
}

/// `collapseSingle` keeps one Point, LineString, or Polygon as that type.
/// Otherwise every result is a Multi* or a GeometryCollection, including a Multi* of one.
private func combinedGeometries(_ items: [GJGeometry], collapseSingle: Bool) -> GJGeometry? {
    let flat = items.flatMap { $0.parts() }
    guard !flat.isEmpty else { return nil }
    if collapseSingle, flat.count == 1 { return flat[0] }

    if let coordinates = uniform(flat, { if case .point(let coordinates) = $0 { return coordinates }; return nil }) {
        return .multiPoint(coordinates)
    }
    if let lines = uniform(flat, { if case .lineString(let coordinates) = $0 { return coordinates }; return nil }) {
        return .multiLineString(lines)
    }
    if let polygons = uniform(flat, { if case .polygon(let coordinates) = $0 { return coordinates }; return nil }) {
        return .multiPolygon(polygons)
    }
    return .collection(flat)
}

private func uniform<T>(_ items: [GJGeometry], _ pick: (GJGeometry) -> T?) -> [T]? {
    var values: [T] = []
    values.reserveCapacity(items.count)
    for item in items {
        guard let value = pick(item) else { return nil }
        values.append(value)
    }
    return values
}

private func sameLonLat(_ a: [Double], _ b: [Double]) -> Bool {
    a.count >= 2 && b.count >= 2 && a[0] == b[0] && a[1] == b[1]
}

/// GeoJSON polygon rings are closed and have at least four positions.
private func closedRing(_ positions: [[Double]]) -> [[Double]]? {
    guard positions.count >= 3, let first = positions.first else { return nil }
    var ring = positions
    if let last = ring.last, !sameLonLat(first, last) {
        ring.append(first)
    }
    guard ring.count >= 4 else { return nil }
    return ring
}

private func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - Coordinates

/// KML tuples are `lon,lat[,alt]`, separated by whitespace. Spaces around commas are accepted.
private func parseKMLCoordinates(_ text: String) -> [[Double]] {
    let scanner = Scanner(string: text)
    var tuples: [[Double]] = []
    while !scanner.isAtEnd {
        let start = scanner.currentIndex
        var components: [Double] = []
        while let value = scanner.scanDouble() {
            components.append(value)
            let mark = scanner.currentIndex
            if scanner.scanString(",") == nil {
                scanner.currentIndex = mark
                break
            }
        }
        if components.count >= 2 {
            if components.count >= 3 {
                tuples.append([components[0], components[1], components[2]])
            } else {
                tuples.append([components[0], components[1]])
            }
        } else if scanner.currentIndex == start {
            guard start < text.endIndex else { break }
            scanner.currentIndex = text.index(after: start)
        }
    }
    return tuples
}

private func parseDoubles(_ text: String) -> [Double] {
    let scanner = Scanner(string: text)
    var values: [Double] = []
    while let value = scanner.scanDouble() {
        values.append(value)
    }
    return values
}

// MARK: - XML

private func xmlLocalName(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
}

private func parseXML(_ data: Data, delegate: XMLParserDelegate) -> Bool {
    // `XMLParser(data:)` fails on documents of about 10 MB (parser error 1).
    // The stream reads the same bytes in chunks and parses those files.
    let parser = XMLParser(stream: InputStream(data: data))
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    return parser.parse()
}

// MARK: - KML

private let kmlIgnored: Set<String> = [
    "NetworkLink", "GroundOverlay", "ScreenOverlay", "PhotoOverlay", "Style", "StyleMap"
]

/// These are valid KML. A file that has one and no supported geometry is not broken.
private let kmlUnpreviewable: Set<String> = [
    "NetworkLink", "GroundOverlay", "ScreenOverlay", "PhotoOverlay"
]

/// Document element that means the file is KML when it has no `<kml>` wrapper.
/// A KMZ root is sometimes a bare NetworkLink.
private let kmlDocumentElements: Set<String> = [
    "kml", "Document", "Folder", "Placemark",
    "NetworkLink", "GroundOverlay", "ScreenOverlay", "PhotoOverlay"
]

private enum KMLRead {
    case features([GJFeature])
    case nothingToPreview
    case invalid
}

private final class KMLElement {
    let name: String
    let attributes: [String: String]
    var text = ""
    var properties = OrderedProperties()
    var geometries: [GJGeometry] = []
    var positions: [[Double]] = []
    var outerRing: [[Double]]?
    var innerRings: [[[Double]]] = []
    var valueText: String?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

private final class KMLConverter: NSObject, XMLParserDelegate {
    private(set) var failed = false
    private var features: [GJFeature] = []
    private var stack: [KMLElement] = []
    private var suppress = 0
    private var sawKMLRoot = false
    private var sawUnpreviewable = false

    static func read(_ data: Data) -> KMLRead {
        let converter = KMLConverter()
        guard parseXML(data, delegate: converter), !converter.failed else { return .invalid }
        if !converter.features.isEmpty { return .features(converter.features) }
        // Parse succeeded, nothing supported was drawn, and the file is KML
        // that only links out or overlays an image.
        if converter.sawKMLRoot && converter.sawUnpreviewable { return .nothingToPreview }
        return .invalid
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = xmlLocalName(elementName)
        if name == "kml" || (stack.isEmpty && kmlDocumentElements.contains(name)) {
            sawKMLRoot = true
        }
        if kmlUnpreviewable.contains(name) {
            sawUnpreviewable = true
        }
        if suppress > 0 || kmlIgnored.contains(name) {
            suppress += 1
        }
        stack.append(KMLElement(name: name, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        stack.last?.text += whitespaceString
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let frame = stack.popLast() else {
            failed = true
            return
        }
        if suppress > 0 {
            suppress -= 1
            return
        }
        accept(frame)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        Data()
    }

    private func accept(_ frame: KMLElement) {
        let parent = stack.last
        switch frame.name {
        case "name", "description":
            guard let parent, parent.name == "Placemark", let value = trimmed(frame.text) else { return }
            parent.properties[frame.name] = value
        case "value":
            if parent?.name == "Data" { parent?.valueText = frame.text }
        case "Data":
            guard let parent, let key = trimmed(frame.attributes["name"] ?? ""),
                  let value = trimmed(frame.valueText ?? "") else { return }
            parent.properties[key] = value
        case "SimpleData":
            guard let parent, let key = trimmed(frame.attributes["name"] ?? ""),
                  let value = trimmed(frame.text) else { return }
            parent.properties[key] = value
        case "SchemaData", "ExtendedData":
            guard let parent else { return }
            var incoming = frame.properties
            // The placemark's own name and description win over ExtendedData.
            if parent.name == "Placemark" {
                if parent.properties["name"] != nil { incoming.remove("name") }
                if parent.properties["description"] != nil { incoming.remove("description") }
            }
            parent.properties.merge(incoming)
        case "coordinates":
            parent?.positions.append(contentsOf: parseKMLCoordinates(frame.text))
        case "coord":
            guard let parent, parent.name == "Track" else { return }
            let numbers = parseDoubles(frame.text)
            guard numbers.count >= 2 else { return }
            if numbers.count >= 3 {
                parent.positions.append([numbers[0], numbers[1], numbers[2]])
            } else {
                parent.positions.append([numbers[0], numbers[1]])
            }
        case "Point":
            if let parent, let first = frame.positions.first {
                parent.geometries.append(.point(first))
            }
        case "LineString":
            if let parent, frame.positions.count >= 2 {
                parent.geometries.append(.lineString(frame.positions))
            }
        case "LinearRing":
            guard let parent else { return }
            if parent.name == "outerBoundaryIs" || parent.name == "innerBoundaryIs" {
                if let ring = closedRing(frame.positions) { parent.positions = ring }
            } else if frame.positions.count >= 2 {
                var line = frame.positions
                if let first = line.first, let last = line.last, !sameLonLat(first, last) {
                    line.append(first)
                }
                parent.geometries.append(.lineString(line))
            }
        case "outerBoundaryIs":
            if let parent, !frame.positions.isEmpty { parent.outerRing = frame.positions }
        case "innerBoundaryIs":
            if let parent, !frame.positions.isEmpty { parent.innerRings.append(frame.positions) }
        case "Polygon":
            if let parent, let outer = frame.outerRing {
                parent.geometries.append(.polygon([outer] + frame.innerRings))
            }
        case "Track":
            if let parent, frame.positions.count >= 2 {
                parent.geometries.append(.lineString(frame.positions))
            }
        case "MultiTrack":
            if let parent, let geometry = combinedGeometries(frame.geometries, collapseSingle: true) {
                parent.geometries.append(geometry)
            }
        case "MultiGeometry":
            if let parent, let geometry = combinedGeometries(frame.geometries, collapseSingle: false) {
                parent.geometries.append(geometry)
            }
        case "Placemark":
            guard let geometry = placemarkGeometry(frame.geometries) else { return }
            frame.properties.pinNameAndDescription()
            features.append(featureObject(geometry, frame.properties))
        default:
            break
        }
    }
}

/// One child geometry is kept, so a MultiGeometry stays a Multi* of one. Siblings are combined.
private func placemarkGeometry(_ geometries: [GJGeometry]) -> GJGeometry? {
    if geometries.count == 1 { return geometries[0] }
    return combinedGeometries(geometries, collapseSingle: false)
}

// MARK: - GPX

private final class GPXElement {
    let name: String
    let attributes: [String: String]
    var text = ""
    var properties = OrderedProperties()
    var ele: String?
    var time: String?
    var points: [[Double]] = []
    var segments: [[[Double]]] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

private final class GPXConverter: NSObject, XMLParserDelegate {
    private(set) var failed = false
    private var features: [GJFeature] = []
    private var stack: [GPXElement] = []

    static func features(in data: Data) -> [GJFeature]? {
        let converter = GPXConverter()
        guard parseXML(data, delegate: converter), !converter.failed else { return nil }
        return converter.features
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        stack.append(GPXElement(name: xmlLocalName(elementName), attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        stack.last?.text += whitespaceString
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let frame = stack.popLast() else {
            failed = true
            return
        }
        accept(frame)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        Data()
    }

    private func accept(_ frame: GPXElement) {
        let parent = stack.last
        switch frame.name {
        case "ele":
            if let parent, parent.name == "wpt" || parent.name == "rtept" || parent.name == "trkpt" {
                parent.ele = frame.text
                if parent.name == "wpt", let value = trimmed(frame.text) {
                    parent.properties["ele"] = Double(value) ?? value
                }
            }
        case "time":
            if let parent, parent.name == "wpt" || parent.name == "rtept" || parent.name == "trkpt" {
                parent.time = frame.text
                if parent.name == "wpt", let value = trimmed(frame.text) {
                    parent.properties["time"] = value
                }
            }
        case "name", "desc", "type":
            guard let parent, parent.name == "wpt" || parent.name == "rte" || parent.name == "trk",
                  let value = trimmed(frame.text) else { return }
            parent.properties[frame.name] = value
        case "wpt":
            guard let position = gpxPosition(frame.attributes, ele: frame.ele) else { return }
            features.append(featureObject(.point(position), frame.properties))
        case "rtept", "trkpt":
            if let parent, let position = gpxPosition(frame.attributes, ele: frame.ele) {
                parent.points.append(position)
            }
        case "trkseg":
            guard let parent else { return }
            if frame.points.count >= 2 {
                parent.segments.append(frame.points)
            } else if let only = frame.points.first, frame.points.count == 1 {
                parent.points.append(only)
            }
        case "rte":
            guard let geometry = gpxRouteGeometry(frame.points) else { return }
            features.append(featureObject(geometry, frame.properties))
        case "trk":
            guard let geometry = gpxTrackGeometry(segments: frame.segments, stray: frame.points) else { return }
            features.append(featureObject(geometry, frame.properties))
        default:
            break
        }
    }
}

/// Two or more route points are a LineString. One is a Point. None is skipped.
private func gpxRouteGeometry(_ points: [[Double]]) -> GJGeometry? {
    if points.count >= 2 { return .lineString(points) }
    return gpxLonePoints(points)
}

/// Segments of two or more points stay a line. A shorter segment is dropped
/// when the track already has a line. With no line, the leftover points are
/// a Point or a MultiPoint. An empty track is skipped.
private func gpxTrackGeometry(segments: [[[Double]]], stray: [[Double]]) -> GJGeometry? {
    if segments.count == 1 { return .lineString(segments[0]) }
    if segments.count > 1 { return .multiLineString(segments) }
    return gpxLonePoints(stray)
}

private func gpxLonePoints(_ points: [[Double]]) -> GJGeometry? {
    if points.count == 1 { return .point(points[0]) }
    if points.count > 1 { return .multiPoint(points) }
    return nil
}

/// `lat` and `lon` are attributes. `ele` becomes the altitude when it parses.
private func gpxPosition(_ attributes: [String: String], ele: String?) -> [Double]? {
    guard let lat = Double(attributes["lat"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
          let lon = Double(attributes["lon"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
        return nil
    }
    if let ele, let altitude = Double(ele.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return [lon, lat, altitude]
    }
    return [lon, lat]
}

// MARK: - KMZ

/// Root `doc.kml`, then the first root `.kml`. When the archive has neither,
/// a `doc.kml` at any depth, then the first `.kml` anywhere.
private func kmlDocument(in kmz: Data) -> Data? {
    guard let entries = ZipArchive.entries(in: kmz) else { return nil }
    let root = entries.filter { isZipRoot($0.name) }
    if let document = root.first(where: { $0.name == "doc.kml" }) {
        return document.data
    }
    if let document = root.first(where: { $0.name.lowercased().hasSuffix(".kml") }) {
        return document.data
    }
    if let document = entries.first(where: { zipFileName($0.name) == "doc.kml" }) {
        return document.data
    }
    return entries.first(where: { $0.name.lowercased().hasSuffix(".kml") })?.data
}

private func zipFileName(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
}

private func isZipRoot(_ name: String) -> Bool {
    !name.isEmpty && !name.hasSuffix("/") && !name.contains("/")
}

private struct ZipEntry {
    var name: String
    var data: Data
}

/// Reads stored and raw-deflate entries. ZIP method 8 is raw DEFLATE
/// (`inflateInit2` with a window of -15), which is not the zlib wrapper.
private enum ZipArchive {
    static func entries(in data: Data) -> [ZipEntry]? {
        guard let eocd = endOfCentralDirectory(in: data),
              let totalEntries = u16(data, eocd + 10),
              let size = u32(data, eocd + 12),
              let offset = u32(data, eocd + 16),
              totalEntries != 0xFFFF, size != 0xFFFFFFFF, offset != 0xFFFFFFFF else { return nil }

        var cursor = Int(offset)
        let end = cursor + Int(size)
        guard cursor >= 0, end <= data.count else { return nil }

        var entries: [ZipEntry] = []
        for _ in 0..<Int(totalEntries) {
            guard cursor + 46 <= data.count, u32(data, cursor) == 0x02014b50,
                  let flags = u16(data, cursor + 8),
                  let method = u16(data, cursor + 10),
                  let compressedSize = u32(data, cursor + 20),
                  let uncompressedSize = u32(data, cursor + 24),
                  let nameLength = u16(data, cursor + 28),
                  let extraLength = u16(data, cursor + 30),
                  let commentLength = u16(data, cursor + 32),
                  let localOffset = u32(data, cursor + 42) else { return nil }
            let nameStart = cursor + 46
            let next = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard next <= data.count, let nameData = slice(data, nameStart, Int(nameLength)) else { return nil }
            cursor = next
            let name = decodeZipName(nameData).replacingOccurrences(of: "\\", with: "/")
            if name.hasSuffix("/") || (flags & 1) != 0 { continue }
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                continue
            }
            guard let file = zipEntryData(
                data,
                localOffset: Int(localOffset),
                method: method,
                compressedSize: Int(compressedSize)
            ) else { continue }
            entries.append(ZipEntry(name: name, data: file))
        }
        return entries
    }
}

private func endOfCentralDirectory(in data: Data) -> Int? {
    guard data.count >= 22 else { return nil }
    let window = min(data.count, 22 + 65535)
    var offset = data.count - 22
    let earliest = data.count - window
    while offset >= earliest {
        if u32(data, offset) == 0x06054b50,
           let commentLength = u16(data, offset + 20),
           offset + 22 + Int(commentLength) == data.count {
            return offset
        }
        if offset == 0 { break }
        offset -= 1
    }
    return nil
}

private func zipEntryData(_ data: Data, localOffset: Int, method: UInt16, compressedSize: Int) -> Data? {
    guard localOffset >= 0, localOffset + 30 <= data.count,
          u32(data, localOffset) == 0x04034b50,
          let nameLength = u16(data, localOffset + 26),
          let extraLength = u16(data, localOffset + 28) else { return nil }
    let start = localOffset + 30 + Int(nameLength) + Int(extraLength)
    guard let payload = slice(data, start, compressedSize) else { return nil }
    switch method {
    case 0:
        return payload
    case 8:
        return inflateRawDeflate(payload)
    default:
        return nil
    }
}

private func decodeZipName(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    return String(data: data, encoding: .isoLatin1) ?? ""
}

private func slice(_ data: Data, _ offset: Int, _ length: Int) -> Data? {
    guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { return nil }
    return data.subdata(in: offset..<(offset + length))
}

private func u16(_ data: Data, _ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func u32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func inflateRawDeflate(_ source: Data) -> Data? {
    if source.isEmpty { return Data() }
    #if canImport(zlib)
    var stream = z_stream()
    guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        return nil
    }
    defer { inflateEnd(&stream) }
    let chunk = 65_536
    var output = Data()
    return source.withUnsafeBytes { srcRaw -> Data? in
        guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
        stream.next_in = UnsafeMutablePointer(mutating: src)
        stream.avail_in = uInt(source.count)
        while true {
            var buffer = Data(count: chunk)
            let capacity = buffer.count
            let status: Int32 = buffer.withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return Z_DATA_ERROR }
                stream.next_out = dst
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = chunk - Int(stream.avail_out)
            if produced > 0 {
                output.append(buffer.prefix(produced))
            }
            if status == Z_STREAM_END { return output }
            if status != Z_OK || (produced == 0 && stream.avail_in == 0) { return nil }
        }
    }
    #else
    return nil
    #endif
}
