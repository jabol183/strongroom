import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image metadata and thumbnails via ImageIO, without decoding full-size pixels.
struct ImageInfo {
    var width: Int?
    var height: Int?
    var takenAt: Date?

    static func read(from data: Data) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var info = ImageInfo()
        info.width = props[kCGImagePropertyPixelWidth] as? Int
        info.height = props[kCGImagePropertyPixelHeight] as? Int
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.takenAt = exifFormatter.date(from: raw)
        }
        return info
    }

    static func jpegThumbnail(from data: Data, maxPixelSize: Int = 400) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, as: .jpeg, quality: 0.8)
    }

    /// Preferred extension for the image's container format ("heic", "jpeg", "png").
    static func fileExtension(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        return UTType(type)?.preferredFilenameExtension
    }

    /// Re-encodes as HEIC, at most `maxPixelSize` on the long edge, orientation applied and
    /// metadata (including location) dropped. Returns nil if that wouldn't make it smaller.
    static func optimizedHEIC(from data: Data, maxPixelSize: Int = 4096, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = encode(image, as: .heic, quality: quality),
              encoded.count < data.count
        else { return nil }
        return encoded
    }

    static func jpeg(from image: CGImage, quality: Double = 0.8) -> Data? {
        encode(image, as: .jpeg, quality: quality)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
