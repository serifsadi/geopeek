//
//  GeoJSONSniff.swift
//  Shared — compiled into the app, the preview, and the thumbnail appex.
//
//  Cheap root-type check for the thumbnail extension. It looks only at the
//  bytes it is given (the thumbnail reads at most a few KB) and never builds
//  a JSON tree. A root `type` of Feature, FeatureCollection, or one of the
//  seven geometry types means GeoJSON. Anything else, including a `type`
//  nested inside another value, does not.
//

import Foundation

enum GeoJSONSniff {
    /// How many leading bytes the thumbnail extension reads from a `.json` file.
    static let maxPrefixBytes = 8192

    static let rootTypes: Set<String> = [
        "Feature", "FeatureCollection",
        "Point", "MultiPoint",
        "LineString", "MultiLineString",
        "Polygon", "MultiPolygon",
        "GeometryCollection"
    ]

    /// The root object's `type` when `data` begins a GeoJSON value and that
    /// string occurs inside `data`. Nil when it does not, or when `data` ends
    /// before the root type is known.
    static func rootType(in data: Data) -> String? {
        var parser = Parser(bytes: [UInt8](data))
        return parser.rootType()
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func rootType() -> String? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        skipWhitespace()
        guard consume(ascii: "{") else { return nil }

        while true {
            skipWhitespace()
            if peek(ascii: "}") { return nil }
            guard let key = readString() else { return nil }
            skipWhitespace()
            guard consume(ascii: ":") else { return nil }
            skipWhitespace()
            if key == "type" {
                guard let value = readString() else { return nil }
                return GeoJSONSniff.rootTypes.contains(value) ? value : nil
            }
            guard skipValue() else { return nil }
            skipWhitespace()
            if consume(ascii: ",") { continue }
            return nil
        }
    }

    mutating func skipValue() -> Bool {
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        if byte == quote { return readString() != nil }
        if byte == lbrace || byte == lbrack { return skipContainer() }
        if byte == UInt8(ascii: "t") { return consumeLiteral("true") }
        if byte == UInt8(ascii: "f") { return consumeLiteral("false") }
        if byte == UInt8(ascii: "n") { return consumeLiteral("null") }
        if byte == minus || isDigit(byte) { return skipNumber() }
        return false
    }

    /// `index` is on `{` or `[`. Returns false if the value runs past the prefix.
    mutating func skipContainer() -> Bool {
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                guard readString() != nil else { return false }
                continue
            }
            index += 1
            if byte == lbrace || byte == lbrack {
                depth += 1
            } else if byte == rbrace || byte == rbrack {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return false
    }

    mutating func skipNumber() -> Bool {
        guard index < bytes.count else { return false }
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else {
            index = start
            return false
        }
        while index < bytes.count {
            let byte = bytes[index]
            if isDigit(byte) || byte == dot || byte == plus || byte == minus
                || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                index += 1
                continue
            }
            break
        }
        return true
    }

    mutating func consumeLiteral(_ literal: String) -> Bool {
        for scalar in literal.utf8 {
            guard index < bytes.count, bytes[index] == scalar else { return false }
            index += 1
        }
        return true
    }

    /// `index` is on the opening quote. Returns the decoded string, or nil if
    /// the prefix ends inside it.
    mutating func readString() -> String? {
        guard consume(ascii: "\"") else { return nil }
        var raw = [UInt8]()
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == quote { return String(bytes: raw, encoding: .utf8) }
            if byte < 0x20 { return nil }
            if byte != backslash {
                raw.append(byte)
                continue
            }
            guard index < bytes.count else { return nil }
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case quote, backslash, slash:
                raw.append(escaped)
            case UInt8(ascii: "b"):
                raw.append(0x08)
            case UInt8(ascii: "f"):
                raw.append(0x0C)
            case UInt8(ascii: "n"):
                raw.append(UInt8(ascii: "\n"))
            case UInt8(ascii: "r"):
                raw.append(UInt8(ascii: "\r"))
            case UInt8(ascii: "t"):
                raw.append(UInt8(ascii: "\t"))
            case UInt8(ascii: "u"):
                guard let scalar = readHexScalar() else { return nil }
                guard let encoded = String(scalar).data(using: .utf8) else { return nil }
                raw.append(contentsOf: encoded)
            default:
                return nil
            }
        }
        return nil
    }

    mutating func readHexScalar() -> UnicodeScalar? {
        var value = 0
        for _ in 0..<4 {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            value <<= 4
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                value += Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                value += Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                value += Int(byte - UInt8(ascii: "A")) + 10
            default:
                return nil
            }
        }
        return UnicodeScalar(UInt32(value))
    }

    mutating func skipWhitespace() {
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
    }

    func peek(ascii: Unicode.Scalar) -> Bool {
        index < bytes.count && bytes[index] == UInt8(ascii: ascii)
    }

    mutating func consume(ascii: Unicode.Scalar) -> Bool {
        guard peek(ascii: ascii) else { return false }
        index += 1
        return true
    }
}

private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let slash = UInt8(ascii: "/")
private let lbrace = UInt8(ascii: "{")
private let rbrace = UInt8(ascii: "}")
private let lbrack = UInt8(ascii: "[")
private let rbrack = UInt8(ascii: "]")
private let dot = UInt8(ascii: ".")
private let plus = UInt8(ascii: "+")
private let minus = UInt8(ascii: "-")

private func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
}

private func isWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
}
