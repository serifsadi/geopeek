//
//  ThumbnailLayout.swift
//  Shared — compiled into the thumbnail appex and the Linux harness.
//
//  The icon is drawn in points. Quick Look's currentContextDrawing context
//  already includes the request scale in its transform, so the rect must be
//  the point canvas (aspect-fit), not the pixel buffer and not half of it.
//

import Foundation

enum ThumbnailLayout {
    /// Centered square that aspect-fits a square icon in a point-sized canvas.
    static func iconRect(width: Double, height: Double) -> (x: Double, y: Double, side: Double) {
        guard width > 0, height > 0 else { return (0, 0, 0) }
        let side = min(width, height)
        return ((width - side) / 2, (height - side) / 2, side)
    }

    /// Pixel edge of the bitmap Quick Look allocates for `points` at `scale`.
    static func bitmapEdge(points: Double, scale: Double) -> Double {
        points * scale
    }
}
