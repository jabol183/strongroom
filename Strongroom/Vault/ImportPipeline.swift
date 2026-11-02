import AVFoundation
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// "Optimized" re-encodes photos to HEIC (max 4096 px) and videos to HEVC 1080p when
/// that makes them smaller. "Original" stores the exact bytes.
enum StorageMode: String, CaseIterable, Identifiable, Sendable {
    case optimized, original
    var id: String { rawValue }
    var title: String { self == .optimized ? "Optimized" : "Original" }

    static let defaultsKey = "storageMode"
    static var current: StorageMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(StorageMode.init) ?? .optimized
    }
}

/// Turns picked media and files into `ImportSource`s: optimizes, reads metadata, makes thumbnails.
/// Runs outside the vault actor so slow work (video export) doesn't block vault access.
enum ImportPipeline {
    static func photo(_ data: Data, mode: StorageMode, folderID: UUID?, name: String? = nil) -> ImportSource {
        let info = ImageInfo.read(from: data)
        var payload = data
        var ext = ImageInfo.fileExtension(of: data) ?? "jpg"
        if mode == .optimized, let optimized = ImageInfo.optimizedHEIC(from: data) {
            payload = optimized
            ext = "heic"
        }
        let finalInfo = mode == .optimized ? (ImageInfo.read(from: payload) ?? info) : info
        let takenAt = info?.takenAt
        return ImportSource(
            payload: .data(payload),
            kind: .photo,
            name: name ?? defaultName(prefix: "IMG", date: takenAt ?? Date()),
            fileExtension: ext,
            takenAt: takenAt,
            pixelWidth: finalInfo?.width,
            pixelHeight: finalInfo?.height,
            thumbnailJPEG: ImageInfo.jpegThumbnail(from: payload),
            folderID: folderID
        )
    }

    /// Returns the source plus any extra temporary file it created (delete after `Vault.add`).
    static func video(at url: URL, mode: StorageMode, folderID: UUID?) async -> (ImportSource, URL?) {
        let asset = AVURLAsset(url: url)
        var fileURL = url
        var created: URL?
        if mode == .optimized, let optimized = await exportHEVC(asset: asset) {
            let originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            let optimizedSize = (try? optimized.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            if optimizedSize < originalSize {
                fileURL = optimized
                created = optimized
            } else {
                TempFiles.remove(optimized)
            }
        }
        let duration = try? await asset.load(.duration).seconds
        let size = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        var takenAt: Date?
        if let item = try? await asset.load(.creationDate) {
            takenAt = try? await item.load(.dateValue)
        }
        let source = ImportSource(
            payload: .file(fileURL),
            kind: .video,
            name: defaultName(prefix: "VID", date: takenAt ?? Date()),
            fileExtension: fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension.lowercased(),
            takenAt: takenAt,
            pixelWidth: size.map { Int(abs($0.width)) },
            pixelHeight: size.map { Int(abs($0.height)) },
            duration: duration.flatMap { $0.isFinite ? $0 : nil },
            thumbnailJPEG: await videoThumbnail(asset: asset),
            folderID: folderID
        )
        return (source, created)
    }

    static func file(at url: URL, folderID: UUID?) async -> ImportSource {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            return photo(data, mode: .original, folderID: folderID, name: url.deletingPathExtension().lastPathComponent)
        }
        return ImportSource(
            payload: .file(url),
            kind: .file,
            name: url.deletingPathExtension().lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            thumbnailJPEG: await fileThumbnail(url: url),
            folderID: folderID
        )
    }

    // MARK: Helpers

    static func defaultName(prefix: String, date: Date) -> String {
        "\(prefix) \(nameFormatter.string(from: date))"
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static func exportHEVC(asset: AVURLAsset) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080),
              let output = try? TempFiles.newURL(name: "optimized.mov")
        else { return nil }
        session.outputURL = output
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false
        await session.export()
        guard session.status == .completed else {
            TempFiles.remove(output)
            return nil
        }
        return output
    }

    private static func videoThumbnail(asset: AVURLAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else {
            return nil
        }
        return ImageInfo.jpeg(from: image)
    }

    private static func fileThumbnail(url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 200, height: 200), scale: 2, representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return ImageInfo.jpeg(from: representation.cgImage)
    }
}
