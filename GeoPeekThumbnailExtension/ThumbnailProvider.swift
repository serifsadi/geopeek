//
//  ThumbnailProvider.swift
//  GeoPeekThumbnailExtension
//
//  Static GeoPeek icon. `.geojson` never opens the file. `.json` sniffs at
//  most a few KB for a GeoJSON root type and otherwise declines so Quick Look
//  keeps the system text thumbnail.
//

import AppKit
import Foundation
import os
import QuickLookThumbnailing

private let thumbnailLog = Logger(subsystem: "dev.serifsadi.GeoPeek.GeoPeekThumbnailExtension",
                                  category: "thumbnail")

private enum ThumbnailError: Error {
    case notGeoJSON
}

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let ext = request.fileURL.pathExtension.lowercased()
        thumbnailLog.log("provideThumbnail ext=\(ext, privacy: .public) size=\(request.maximumSize.width, privacy: .public)x\(request.maximumSize.height, privacy: .public) scale=\(request.scale, privacy: .public)")
        if ext == "geojson" {
            handler(Self.iconReply(for: request), nil)
            return
        }
        if ext == "json" {
            if Self.sniffIsGeoJSON(request.fileURL) {
                handler(Self.iconReply(for: request), nil)
            } else {
                handler(nil, ThumbnailError.notGeoJSON)
            }
            return
        }
        handler(nil, ThumbnailError.notGeoJSON)
    }

    // MARK: - JSON sniff

    /// True when the first few KB contain a GeoJSON root `type`. Does not
    /// parse the rest of the file.
    private static func sniffIsGeoJSON(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: GeoJSONSniff.maxPrefixBytes),
              !prefix.isEmpty else { return false }
        return GeoJSONSniff.rootType(in: prefix) != nil
    }

    // MARK: - Icon

    /// `currentContextDrawing` is AppKit points. The context transform already
    /// includes `request.scale`, so drawing the point rect fills a 2x or 3x bitmap.
    /// Drawing that same rect with the Core Graphics reply left the icon at
    /// half size in the bottom-left of a scale-2 buffer.
    private static func iconReply(for request: QLFileThumbnailRequest) -> QLThumbnailReply {
        let size = canvasSize(for: request)
        return QLThumbnailReply(contextSize: size, currentContextDrawing: {
            let fitted = ThumbnailLayout.iconRect(width: size.width, height: size.height)
            let rect = NSRect(x: fitted.x, y: fitted.y, width: fitted.side, height: fitted.side)
            if let icon = Self.icon {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high])
            } else {
                Self.drawFallback(in: rect)
            }
            return true
        })
    }

    /// Use the requested maximum, in points, so the reply matches the size
    /// Quick Look asked for. A zero size is replaced so the reply is not rejected.
    private static func canvasSize(for request: QLFileThumbnailRequest) -> CGSize {
        let width = request.maximumSize.width
        let height = request.maximumSize.height
        if width.isFinite, height.isFinite, width >= 1, height >= 1 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 256, height: 256)
    }

    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ThumbnailIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// Used only when the bundled icon is missing. Same point rect as the image,
    /// so a fallback still fills the context instead of one quadrant.
    private static func drawFallback(in rect: NSRect) {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.22, yRadius: inset.height * 0.22).fill()
        NSColor(srgbRed: 0.976, green: 0.451, blue: 0.086, alpha: 1).setFill()
        let path = NSBezierPath()
        let radius = inset.width * 0.22
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2
            let point = NSPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.fill()
    }
}
