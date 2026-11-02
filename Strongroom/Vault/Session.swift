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
    @Published private(set) var items: [VaultIndex.Item] = []
    @Published var message: String?
    @Published private(set) var importProgress: (done: Int, total: Int)?

    let thumbnails = NSCache<NSUUID, UIImage>()
    private let storage: BlobStorage?

    init() {
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

    private func open(_ vault: Vault) async {
        let loaded = await vault.items
        // If the app went to the background while unlocking, stay locked.
        guard case .unlocking = state else { return }
        items = loaded
        state = .unlocked(vault)
    }

    func lock() {
        state = .locked
        items = []
        message = nil
        importProgress = nil
        thumbnails.removeAllObjects()
    }

    // MARK: Vault actions

    func importPhotos(_ selection: [PhotosPickerItem]) async {
        guard let vault else { return }
        importProgress = (0, selection.count)
        var failures = 0
        for (offset, pickerItem) in selection.enumerated() {
            do {
                guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                    failures += 1
                    continue
                }
                try await vault.importPhoto(data)
            } catch {
                failures += 1
            }
            // Stop quietly if the app locked mid-import.
            guard self.vault === vault else { return }
            importProgress = (offset + 1, selection.count)
        }
        items = await vault.items
        importProgress = nil
        if failures > 0 { message = "\(failures) item(s) couldn't be imported." }
    }

    func delete(_ item: VaultIndex.Item) async {
        guard let vault else { return }
        do {
            try await vault.delete(item)
            thumbnails.removeObject(forKey: item.id as NSUUID)
            items = await vault.items
        } catch {
            message = "Couldn't delete. (\(error.localizedDescription))"
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 60 ? [.hour, .minute] : [.second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(seconds, 1)) ?? "a moment"
    }
}
