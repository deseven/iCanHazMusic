import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// In-memory images for the artwork tests (no files needed).
enum TestImages {
    /// A `width` x `height` image: left half red, right half blue (so a crop's content can be checked).
    static func make(width: Int, height: Int, alpha: Bool = false, type: UTType = .png) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = context.makeImage()!

        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// Pixel size and container type of encoded image data.
    static func inspect(_ data: Data) -> (width: Int, height: Int, type: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              let type = CGImageSourceGetType(source) as String? else { return nil }
        return (w, h, type)
    }
}
