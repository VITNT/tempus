import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Still-image helpers: HEIC frames for screenshot mode and small JPEG thumbnails.
nonisolated enum Stills {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let thumbnailWidth: CGFloat = 640

    /// HEIC at quality 0.9 keeps UI text crisp at a fraction of PNG's size.
    static func writeHEIC(_ image: CIImage, to url: URL) throws {
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        try context.writeHEIFRepresentation(
            of: image, to: url, format: .RGBA8, colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    }

    /// Downscaled copy for previews and the gallery.
    static func thumbnail(of image: CIImage, maxWidth: CGFloat = thumbnailWidth) -> CGImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, maxWidth / extent.width)
        let scaled = scale < 1
            ? image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            : image
        return context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Small decoded copy for filmstrips; uses the file's embedded thumbnail when it has one.
    static func loadThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    /// Pixel size from the file header, without decoding the image.
    static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
