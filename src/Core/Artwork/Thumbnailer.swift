// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Turns whatever image an album came with (often a multi-megapixel scan) into the small square
/// thumbnail that gets cached. ImageIO + CoreGraphics only, safe to call from any thread.
enum Thumbnailer {
    /// Biggest intermediate image we ask ImageIO for, so a freak 20000x50 banner can't eat the memory.
    private static let maxIntermediatePixels = 4096
    private static let jpegQuality = 0.85

    /// A `pixels` x `pixels` thumbnail of `data` (aspect-fill, centered crop), encoded as JPEG, or as PNG
    /// if the image has transparency. nil if `data` isn't an image ImageIO can decode.
    static func thumbnail(from data: Data, pixels: Int) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }

        // ImageIO keeps the aspect ratio and fits the *longer* side, so ask for enough to cover the square.
        let longer = Double(max(width, height)), shorter = Double(min(width, height))
        let wanted = min(maxIntermediatePixels, Int((Double(pixels) * longer / shorter).rounded(.up)))
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(wanted, pixels),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }

        let hasAlpha: Bool
        switch scaled.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high

        let side = CGFloat(pixels)
        let scale = max(side / CGFloat(scaled.width), side / CGFloat(scaled.height))
        let w = CGFloat(scaled.width) * scale, h = CGFloat(scaled.height) * scale
        context.draw(scaled, in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        guard let square = context.makeImage() else { return nil }

        return encode(square, asPNG: hasAlpha)
    }

    private static func encode(_ image: CGImage, asPNG: Bool) -> Data? {
        let out = NSMutableData()
        let type = (asPNG ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let options = asPNG ? nil : [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
