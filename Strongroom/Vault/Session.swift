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
        /// A vault was just created; show its recovery phrase before entering.
        case newVaultPhrase(Vault)
        /// Opened with the recovery phrase; the user draws a new pattern (twice).
        case choosingPattern(Vault, first: Pattern?)
        case unlocked(Vault)
        /// Someone else's shared vault, opened read-only from a temporary folder.
        case viewingShare(Vault, allowExport: Bool)
    }

    @Published private(set) var state: State = .locked
    @Published private(set) var snapshot = VaultSnapshot()
    @Published var message: String?
    @Published private(set) var progress: (label: String, done: Int, total: Int)?
    @Published private(set) var syncState: SyncState = .idle

    enum SyncState: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    let thumbnails = NSCache<NSUUID, UIImage>()
    let storage: BlobStorage?
    let backupStore: BackupStore = CloudKitBackupStore()
    let shareStore: ShareStore = CloudKitShareStore()
    private var syncTask: Task<Void, Never>?

    init() {
        TempFiles.wipe()
        storage = try? BlobStorage.appDefault()
        if storage == nil { message = "Storage couldn't be prepared." }
    }

    /// The open vault, in any state where one is open.
    var vault: Vault? {
        switch state {
        case .unlocked(let vault), .newVaultPhrase(let vault), .choosingPattern(let vault, _), .viewingShare(let vault, _): vault
        default: nil
        }
    }

    var isReadOnly: Bool {
        if case .viewingShare = state { return true }
        return false
    }

    var canExport: Bool {
        if case .viewingShare(_, let allowExport) = state { return allowExport }
        return true
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
        case .choosingPattern(let vault, nil):
            state = .choosingPattern(vault, first: pattern)
            message = "Draw the same pattern again to confirm."
        case .choosingPattern(let vault, let first?):
            guard pattern == first else {
                state = .choosingPattern(vault, first: nil)
                message = "Patterns didn't match. Draw a new pattern."
                return
            }
            Task { await adoptPattern(pattern, for: vault) }
        case .unlocking, .unlocked, .newVaultPhrase, .viewingShare:
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
                    if await vault.snapshot().settings.isDuress {
                        _ = try? await vault.wipeOtherVaults()
                    }
                    await enter(vault, as: { .unlocked($0) })
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
                let vault = try await Task.detached(priority: .userInitiated) {
                    let vault = try pending.create()
                    try await vault.setRecoveryPhrase(try RecoveryPhrase.generate())
                    return vault
                }.value
                AttemptThrottle.reset()
                await enter(vault, as: { .newVaultPhrase($0) })
            } catch {
                guard case .unlocking = state else { return }
                state = .locked
                message = "Couldn't create the vault. (\(error.localizedDescription))"
            }
        }
    }

    /// Loads the snapshot and switches state, unless the app locked in the meantime.
    private func enter(_ vault: Vault, as makeState: (Vault) -> State) async {
        let loaded = await vault.snapshot()
        guard case .unlocking = state else { return }
        snapshot = loaded
        state = makeState(vault)
        if case .unlocked = state {
            scheduleSync(after: .seconds(1))
            Task { await cleanUpExpiredShares() }
        }
    }

    /// After the new-vault phrase screen. A custom phrase replaces the generated one.
    func finishPhraseSetup(customPhrase: String?) async -> Bool {
        guard case .newVaultPhrase(let vault) = state else { return false }
        if let customPhrase {
            do {
                try RecoveryPhrase.validateCustom(customPhrase)
                try await vault.setRecoveryPhrase(customPhrase)
            } catch let error as RecoveryPhrase.ValidationError {
                message = error.message
                return false
            } catch {
                message = "Couldn't save the phrase. (\(error.localizedDescription))"
                return false
            }
        }
        snapshot = await vault.snapshot()
        state = .unlocked(vault)
        scheduleSync(after: .seconds(1))
        return true
    }

    /// Opens a vault on this device with its recovery phrase, then asks for a new pattern.
    func recover(phrase: String) async -> Bool {
        guard let storage, case .locked = state else { return false }
        state = .unlocking
        message = nil
        do {
            var found = try await Task.detached(priority: .userInitiated) {
                try Vault.recover(phrase: phrase, storage: storage)
            }.value
            guard case .unlocking = state else { return false }
            if found == nil, CloudKitBackupStore.isConfigured {
                found = try await restoreFromCloud(phrase: phrase, storage: storage)
                guard case .unlocking = state else { return false }
            }
            guard let vault = found else {
                state = .locked
                message = "No vault on this device or in iCloud opens with that phrase."
                return false
            }
            await enter(vault, as: { .choosingPattern($0, first: nil) })
            message = "Phrase accepted. Draw a new pattern for this vault."
            return true
        } catch {
            if case .unlocking = state { state = .locked }
            message = "Couldn't recover. (\(error.localizedDescription))"
            return false
        }
    }

    private func restoreFromCloud(phrase: String, storage: BlobStorage) async throws -> Vault? {
        try await CloudKitBackupStore.checkAvailable()
        progress = ("Downloading", 0, 1)
        defer { progress = nil }
        return try await CloudSync.restore(phrase: phrase, storage: storage, store: backupStore) { done, total in
            Task { @MainActor [weak self] in self?.progress = ("Downloading", done, total) }
        }
    }

    private func adoptPattern(_ pattern: Pattern, for vault: Vault) async {
        state = .unlocking
        do {
            try await Task.detached(priority: .userInitiated) {
                try await vault.changePattern(to: pattern, deviceSalt: try Keychain.deviceSalt())
            }.value
            await enter(vault, as: { .unlocked($0) })
        } catch {
            guard case .unlocking = state else { return }
            state = .choosingPattern(vault, first: nil)
            message = error.localizedDescription
        }
    }

    func lock() {
        syncTask?.cancel()
        syncTask = nil
        syncState = .idle
        state = .locked
        snapshot = VaultSnapshot()
        message = nil
        progress = nil
        thumbnails.removeAllObjects()
        TempFiles.wipe()
    }

    // MARK: Security settings

    func changePattern(to pattern: Pattern) async throws {
        guard let vault else { return }
        try await Task.detached(priority: .userInitiated) {
            try await vault.changePattern(to: pattern, deviceSalt: try Keychain.deviceSalt())
        }.value
    }

    func changeRecoveryPhrase(to phrase: String, custom: Bool) async throws {
        guard let vault else { return }
        if custom { try RecoveryPhrase.validateCustom(phrase) }
        let store = backupStore
        let hadBackup = snapshot.settings.lastBackupRevision > 0 && CloudKitBackupStore.isConfigured
        try await Task.detached(priority: .userInitiated) {
            let oldKeys = try? await vault.recoveryKeys()
            try await vault.setRecoveryPhrase(phrase)
            if hadBackup, let oldKeys {
                // Best effort: move the backup so the new phrase finds it. Sync retries otherwise.
                try? await CloudSync(store: store).rekey(vault, from: oldKeys, to: try await vault.recoveryKeys())
            }
        }.value
        await refresh()
        scheduleSync()
    }

    func setDuress(_ enabled: Bool) async {
        await perform("Couldn't change duress mode.") { vault in
            try await vault.updateSettings { $0.isDuress = enabled }
        }
    }

    func deleteVault() async {
        guard let vault else { return }
        syncTask?.cancel()
        if snapshot.settings.lastBackupRevision > 0, CloudKitBackupStore.isConfigured {
            progress = ("Deleting iCloud copy", 0, 1)
            try? await CloudSync(store: backupStore).deleteBackup(vault)
        }
        await vault.destroy()
        lock()
    }

    // MARK: Sharing

    /// Opens someone's shared vault by its share phrase.
    func joinShare(phrase: String) async -> Bool {
        guard case .locked = state else { return false }
        guard CloudKitBackupStore.isConfigured else {
            message = "Shared vaults need iCloud, which isn't enabled in this build."
            return false
        }
        state = .unlocking
        message = nil
        progress = ("Downloading", 0, 1)
        defer { progress = nil }
        do {
            let storage = try BlobStorage(root: TempFiles.directory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true))
            let opened = try await ShareService(store: shareStore).open(phrase: phrase, into: storage) { done, total in
                Task { @MainActor [weak self] in self?.progress = ("Downloading", done, total) }
            }
            guard case .unlocking = state else { return false }
            await enter(opened.vault, as: { .viewingShare($0, allowExport: opened.allowExport) })
            return true
        } catch {
            if case .unlocking = state { state = .locked }
            message = error.localizedDescription
            return false
        }
    }

    /// Uploads a snapshot of the open vault as a share. Returns the share phrase.
    func createShare(policy: SharePolicy) async throws -> String {
        guard let vault, case .unlocked = state else { throw VaultError.itemNotFound }
        try await CloudKitBackupStore.checkAvailable()
        progress = ("Uploading", 0, 1)
        defer { progress = nil }
        let phrase = try await ShareService(store: shareStore).create(from: vault, policy: policy)
        await refresh()
        scheduleSync()
        return phrase
    }

    func revokeShare(_ share: VaultIndex.ShareRecord) async {
        let store = shareStore
        await perform("Couldn't revoke the share.") { try await ShareService(store: store).revoke(share, in: $0) }
    }

    private func cleanUpExpiredShares() async {
        let now = Date()
        let expired = snapshot.settings.shares.filter { ($0.expiresAt ?? .distantFuture) < now }
        guard !expired.isEmpty, (try? await CloudKitBackupStore.checkAvailable()) != nil else { return }
        for share in expired { await revokeShare(share) }
    }

    // MARK: Backup & sync

    func setBackup(enabled: Bool) async {
        guard let vault else { return }
        if enabled {
            await perform("Couldn't turn on backup.") { try await $0.updateSettings { $0.backupEnabled = true } }
            syncNow()
            return
        }
        syncTask?.cancel()
        syncState = .idle
        if snapshot.settings.lastBackupRevision > 0, CloudKitBackupStore.isConfigured {
            do {
                try await CloudKitBackupStore.checkAvailable()
                try await CloudSync(store: backupStore).deleteBackup(vault)
            } catch {
                message = "Backup is off, but the iCloud copy couldn't be removed. (\(error.localizedDescription))"
            }
        }
        await perform("Couldn't turn off backup.") {
            try await $0.updateSettings {
                $0.backupEnabled = false
                $0.lastBackupRevision = 0
            }
        }
    }

    func syncNow() {
        scheduleSync(after: .zero)
    }

    /// Debounced: bursts of changes produce one sync.
    func scheduleSync(after delay: Duration = .seconds(4)) {
        guard let vault, case .unlocked = state, CloudKitBackupStore.isConfigured,
              snapshot.settings.backupEnabled, snapshot.settings.recoveryPhrase != nil
        else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.runSync(vault)
        }
    }

    private func runSync(_ vault: Vault) async {
        guard self.vault === vault else { return }
        syncState = .syncing
        do {
            try await CloudKitBackupStore.checkAvailable()
            try await CloudSync(store: backupStore).sync(vault)
            guard self.vault === vault else { return }
            syncState = .synced(Date())
            await refresh()
        } catch is CancellationError {
            if self.vault === vault { syncState = .idle }
        } catch {
            guard self.vault === vault, !Task.isCancelled else { return }
            syncState = .failed(error.localizedDescription)
        }
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
        scheduleSync()
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
        scheduleSync()
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
        scheduleSync()
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
        scheduleSync()
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
