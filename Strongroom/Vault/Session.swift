import Photos
import PhotosUI
import SwiftUI

/// App-wide lock state. Owns the open vault; locking drops every reference to it,
/// which releases the master key (CryptoKit zeroes key storage on deallocation).
@MainActor
final class Session: ObservableObject {
    enum State {
        case locked
        case unlocking
        case confirmingNew(first: Pattern, pending: Vault.PendingVault)
        case unlocked(Vault)
    }

    @Published private(set) var state: State = .locked
    @Published private(set) var snapshot = VaultSnapshot()
    @Published var message: String?
    @Published private(set) var progress: (label: String, done: Int, total: Int)?

    let thumbnails = NSCache<NSUUID, UIImage>()
    let storage: BlobStorage?

    init() {
        TempFiles.wipe()
        storage = try? BlobStorage.appDefault()
        if storage == nil { message = "Storage couldn't be prepared." }
    }

    var vault: Vault? {
        if case .unlocked(let vault) = state { return vault }
        return nil
    }

    var isBusy: Bool {
        if case .unlocking = state { return true }
        return false
    }

    // MARK: Unlock flow

    func submit(_ pattern: Pattern) {
        do {
            try pattern.validate()
        } catch let error as Pattern.ValidationError {
            message = error.message
            return
        } catch {
            return
        }

        switch state {
        case .locked:
            unlock(pattern)
        case .confirmingNew(let first, let pending):
            guard pattern == first else {
                state = .locked
                message = "Patterns didn't match. Start again."
                return
            }
            create(pending)
        case .unlocking, .unlocked:
            return
        }
    }

    func cancelCreate() {
        state = .locked
        message = nil
    }

    private func unlock(_ pattern: Pattern) {
        if let wait = AttemptThrottle.waitTime() {
            message = "Too many attempts. Try again in \(Self.format(wait))."
            return
        }
        guard let storage else { return }
        state = .unlocking
        message = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Vault.locate(pattern: pattern, deviceSalt: try Keychain.deviceSalt(), storage: storage)
                }.value
                guard case .unlocking = state else { return }  // locked while deriving
                switch result {
                case .found(let vault):
                    AttemptThrottle.reset()
                    await open(vault)
                case .notFound(let pending):
                    AttemptThrottle.recordMiss()
                    state = .confirmingNew(first: pattern, pending: pending)
                    message = "No vault opens with this pattern. Draw it again to create a new one."
                }
            } catch {
                guard case .unlocking = state else { return }
                state = .locked
                message = "Couldn't unlock. (\(error.localizedDescription))"
            }
        }
    }

    private func create(_ pending: Vault.PendingVault) {
        state = .unlocking
        message = nil
        Task {
            do {
                let vault = try await Task.detached(priority: .userInitiated) { try pending.create() }.value
                AttemptThrottle.reset()
                await open(vault)
            } catch {
                guard case .unlocking = state else { return }
                state = .locked
                message = "Couldn't create the vault. (\(error.localizedDescription))"
            }
        }
    }

    func open(_ vault: Vault) async {
        let loaded = await vault.snapshot()
        // If the app went to the background while unlocking, stay locked.
        guard case .unlocking = state else { return }
        snapshot = loaded
        state = .unlocked(vault)
    }

    func lock() {
        state = .locked
        snapshot = VaultSnapshot()
        message = nil
        progress = nil
        thumbnails.removeAllObjects()
        TempFiles.wipe()
    }

    // MARK: Vault actions

    func refresh() async {
        guard let vault else { return }
        let fresh = await vault.snapshot()
        guard self.vault === vault else { return }
        snapshot = fresh
    }

    /// Runs a vault operation, refreshes the snapshot, and reports failures.
    func perform(_ failureMessage: String, _ operation: @escaping (Vault) async throws -> Void) async {
        guard let vault else { return }
        do {
            try await operation(vault)
        } catch {
            message = "\(failureMessage) (\(error.localizedDescription))"
        }
        await refresh()
    }

    func importFromPhotos(_ selection: [PhotosPickerItem], into folderID: UUID?, deleteOriginals: Bool) async {
        guard let vault, !selection.isEmpty else { return }
        let mode = StorageMode.current
        var failures = 0
        var importedIdentifiers: [String] = []
        progress = ("Encrypting", 0, selection.count)
        for (offset, pickerItem) in selection.enumerated() {
            do {
                if pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let movie = try await pickerItem.loadTransferable(type: PickedMovie.self) else {
                        failures += 1
                        continue
                    }
                    let (source, extra) = await ImportPipeline.video(at: movie.url, mode: mode, folderID: folderID)
                    defer {
                        TempFiles.remove(movie.url)
                        if let extra { TempFiles.remove(extra) }
                    }
                    try await vault.add(source)
                } else {
                    guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                        failures += 1
                        continue
                    }
                    try await vault.add(await Self.preparePhoto(data, mode: mode, folderID: folderID))
                }
                if let identifier = pickerItem.itemIdentifier { importedIdentifiers.append(identifier) }
            } catch {
                failures += 1
            }
            guard self.vault === vault else { return }  // locked mid-import
            progress = ("Encrypting", offset + 1, selection.count)
            await refresh()
        }
        progress = nil
        if failures > 0 { message = "\(failures) item(s) couldn't be imported." }
        if deleteOriginals, !importedIdentifiers.isEmpty {
            await deleteFromPhotoLibrary(importedIdentifiers)
        }
    }

    func importFiles(_ urls: [URL], into folderID: UUID?) async {
        guard let vault, !urls.isEmpty else { return }
        var failures = 0
        progress = ("Encrypting", 0, urls.count)
        for (offset, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await vault.add(await ImportPipeline.file(at: url, folderID: folderID))
            } catch {
                failures += 1
            }
            guard self.vault === vault else { return }
            progress = ("Encrypting", offset + 1, urls.count)
            await refresh()
        }
        progress = nil
        if failures > 0 { message = "\(failures) file(s) couldn't be imported." }
    }

    func importCapture(_ capture: CameraCapture, into folderID: UUID?) async {
        guard let vault else { return }
        let mode = StorageMode.current
        progress = ("Encrypting", 0, 1)
        do {
            switch capture {
            case .photo(let data):
                try await vault.add(await Self.preparePhoto(data, mode: mode, folderID: folderID))
            case .video(let url):
                let (source, extra) = await ImportPipeline.video(at: url, mode: mode, folderID: folderID)
                defer {
                    TempFiles.remove(url)
                    if let extra { TempFiles.remove(extra) }
                }
                try await vault.add(source)
            }
        } catch {
            message = "Couldn't save the capture. (\(error.localizedDescription))"
        }
        progress = nil
        await refresh()
    }

    /// Decrypts items to temporary files for the share sheet. Wiped on lock.
    func exportURLs(for items: [VaultIndex.Item]) async -> [URL] {
        guard let vault else { return [] }
        var urls: [URL] = []
        for item in items {
            if let url = try? await vault.decryptToTemporaryFile(item) { urls.append(url) }
        }
        return urls
    }

    private func deleteFromPhotoLibrary(_ identifiers: [String]) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            message = "Allow full Photos access in Settings to delete originals after import."
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            // The user tapped "Don't Allow" on the system prompt; nothing to do.
        }
    }

    /// HEIC encoding is CPU-heavy; keep it off the main thread.
    private static func preparePhoto(_ data: Data, mode: StorageMode, folderID: UUID?) async -> ImportSource {
        await Task.detached(priority: .userInitiated) {
            ImportPipeline.photo(data, mode: mode, folderID: folderID)
        }.value
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 60 ? [.hour, .minute] : [.second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(seconds, 1)) ?? "a moment"
    }
}

/// A movie picked from Photos, copied into the temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = try TempFiles.newURL(name: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum CameraCapture {
    case photo(Data)
    case video(URL)
}
