//
//  ThumbnailProvider.swift
//  GeoPeekThumbnailExtension
//
//  Created by Şerif Şadi Şenkule on 28.02.2026.
//

import QuickLookThumbnailing
import CoreGraphics
import Foundation

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url  = request.fileURL
        let size = request.maximumSize

        DispatchQueue.global(qos: .userInitiated).async {
            let reply = Self.makeThumbnail(url: url, size: size)
            handler(reply, nil)
        }
    }

    // MARK: - Drawing

    private static let validTypes: Set<String> = [
        "FeatureCollection", "Feature",
        "Point", "MultiPoint",
        "LineString", "MultiLineString",
        "Polygon", "MultiPolygon",
        "GeometryCollection"
    ]

    /// A parsed geometry ready for rendering.
    private struct GeoPath {
        enum Kind { case polygon, line, point }
        let kind:  Kind
        /// Each inner array is one ring/line/position.
        let rings: [[(Double, Double)]]
    }

    /// Files larger than this fall back to the system's generic thumbnail quickly
    /// rather than loading potentially hundreds of MB into extension memory.
    private static let maxFileBytes: Int = 50 * 1_024 * 1_024   // 50 MB

    private static func makeThumbnail(url: URL, size: CGSize) -> QLThumbnailReply? {

        // Fast-path: skip files that would blow the extension's memory budget.
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= maxFileBytes else { return nil }

        guard let data  = try? Data(contentsOf: url),
              let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type  = root["type"] as? String,
              validTypes.contains(type) else { return nil }

        // ── Parse geometries ────────────────────────────────────────────────
        var paths  = [GeoPath]()
        var minLng = Double.infinity,  maxLng = -Double.infinity
        var minLat = Double.infinity,  maxLat = -Double.infinity

        /// Extracts a (lng, lat) pair from a JSON array node; updates bounds.
        func coord(_ v: Any) -> (Double, Double)? {
            guard let a   = v as? [Any], a.count >= 2,
                  let lng = (a[0] as? NSNumber)?.doubleValue,
                  let lat = (a[1] as? NSNumber)?.doubleValue else { return nil }
            if lng < minLng { minLng = lng }; if lng > maxLng { maxLng = lng }
            if lat < minLat { minLat = lat }; if lat > maxLat { maxLat = lat }
            return (lng, lat)
        }

        /// Converts a coordinate-array node (ring / line) into a point list.
        func ring(_ v: Any) -> [(Double, Double)] {
            (v as? [Any])?.compactMap { coord($0) } ?? []
        }

        func geometry(_ g: [String: Any]) {
            guard let gType = g["type"] as? String else { return }

            if gType == "GeometryCollection" {
                (g["geometries"] as? [[String: Any]])?.forEach { geometry($0) }
                return
            }

            guard let raw = g["coordinates"] else { return }

            switch gType {
            case "Point":
                if let c = coord(raw) {
                    paths.append(GeoPath(kind: .point, rings: [[c]]))
                }
            case "MultiPoint":
                if let arr = raw as? [Any] {
                    let pts = arr.compactMap { coord($0) }.map { [$0] }
                    paths.append(GeoPath(kind: .point, rings: pts))
                }
            case "LineString":
                paths.append(GeoPath(kind: .line, rings: [ring(raw)]))
            case "MultiLineString":
                if let arr = raw as? [Any] {
                    paths.append(GeoPath(kind: .line, rings: arr.map { ring($0) }))
                }
            case "Polygon":
                if let arr = raw as? [Any] {
                    paths.append(GeoPath(kind: .polygon, rings: arr.map { ring($0) }))
                }
            case "MultiPolygon":
                if let arr = raw as? [Any] {
                    for poly in arr {
                        if let rings = poly as? [Any] {
                            paths.append(GeoPath(kind: .polygon, rings: rings.map { ring($0) }))
                        }
                    }
                }
            default: break
            }
        }

        switch type {
        case "FeatureCollection":
            (root["features"] as? [[String: Any]])?.forEach {
                if let g = $0["geometry"] as? [String: Any] { geometry(g) }
            }
        case "Feature":
            if let g = root["geometry"] as? [String: Any] { geometry(g) }
        default:
            geometry(root)
        }

        guard !paths.isEmpty, minLng.isFinite else { return nil }

        // ── Projection ──────────────────────────────────────────────────────
        let pw     = Double(size.width)
        let ph     = Double(size.height)
        let pad    = min(pw, ph) * 0.10
        let drawW  = pw - pad * 2
        let drawH  = ph - pad * 2
        let lngSpan = max(maxLng - minLng, 1e-6)
        let latSpan = max(maxLat - minLat, 1e-6)
        let fit    = min(drawW / lngSpan, drawH / latSpan)
        let ox     = pad + (drawW - lngSpan * fit) / 2
        let oy     = pad + (drawH - latSpan * fit) / 2

        func proj(_ c: (Double, Double)) -> CGPoint {
            CGPoint(x: ox + (c.0 - minLng) * fit,
                    y: oy + (c.1 - minLat) * fit) // CG y-up matches lat-up
        }

        // ── Render ──────────────────────────────────────────────────────────
        let reply = QLThumbnailReply(contextSize: size) { ctx in

            let bgColor     = CGColor(red: 0.11,  green: 0.11,  blue: 0.12,  alpha: 1.00)
            let strokeColor = CGColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1.00)
            let fillColor   = CGColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 0.22)

            // Background
            ctx.setFillColor(bgColor)
            ctx.fill(CGRect(origin: .zero, size: size))

            let lw = CGFloat(max(1.0, min(pw, ph) * 0.018))
            ctx.setLineWidth(lw)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)

            for gp in paths {
                switch gp.kind {

                case .polygon:
                    // Fill pass
                    for ring in gp.rings where !ring.isEmpty {
                        ctx.move(to: proj(ring[0]))
                        ring.dropFirst().forEach { ctx.addLine(to: proj($0)) }
                        ctx.closePath()
                    }
                    ctx.setFillColor(fillColor)
                    ctx.fillPath()
                    // Stroke pass
                    for ring in gp.rings where !ring.isEmpty {
                        ctx.move(to: proj(ring[0]))
                        ring.dropFirst().forEach { ctx.addLine(to: proj($0)) }
                        ctx.closePath()
                    }
                    ctx.setStrokeColor(strokeColor)
                    ctx.strokePath()

                case .line:
                    for ring in gp.rings where ring.count >= 2 {
                        ctx.move(to: proj(ring[0]))
                        ring.dropFirst().forEach { ctx.addLine(to: proj($0)) }
                    }
                    ctx.setStrokeColor(strokeColor)
                    ctx.strokePath()

                case .point:
                    let r = CGFloat(max(2.0, min(pw, ph) * 0.040))
                    ctx.setFillColor(strokeColor)
                    for ring in gp.rings {
                        if let c = ring.first {
                            let p = proj(c)
                            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r,
                                                       width: r * 2, height: r * 2))
                        }
                    }
                }
            }
            return true
        }

        return reply
    }
}
