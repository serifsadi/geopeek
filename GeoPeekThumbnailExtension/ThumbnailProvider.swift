//
//  ThumbnailProvider.swift
//  GeoPeekThumbnailExtension
//
//  Static GeoPeek icon. `.geojson` never opens the file. `.json` sniffs at
//  most a few KB for a GeoJSON root type and otherwise declines so Quick Look
//  keeps the system text thumbnail.
//

import CoreGraphics
import Foundation
import ImageIO
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
        thumbnailLog.log("provideThumbnail ext=\(ext, privacy: .public) size=\(request.maximumSize.width, privacy: .public)x\(request.maximumSize.height, privacy: .public)")
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

    private static func iconReply(for request: QLFileThumbnailRequest) -> QLThumbnailReply {
        let size = canvasSize(for: request)
        return QLThumbnailReply(contextSize: size, drawing: { context in
            drawIcon(in: context, size: size)
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

    private static let iconImage: CGImage? = {
        guard let url = Bundle.main.url(forResource: "ThumbnailIcon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    /// Draws the bundled app icon, aspect-fit. The bitmap is already a rounded
    /// tile; a vector mark covers a missing asset so the reply is never empty.
    private static func drawIcon(in context: CGContext, size: CGSize) {
        let side = min(size.width, size.height)
        let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                          width: side, height: side)
        context.setFillColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        if let iconImage {
            context.interpolationQuality = .high
            context.draw(iconImage, in: rect)
            return
        }
        let inset = rect.insetBy(dx: side * 0.08, dy: side * 0.08)
        let radius = inset.width * 0.22
        context.addPath(CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.setFillColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)
        let radiusMark = inset.width * 0.22
        context.beginPath()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2
            let point = CGPoint(x: inset.midX + cos(angle) * radiusMark,
                                y: inset.midY + sin(angle) * radiusMark)
            if i == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.closePath()
        context.fillPath()
    }
}
