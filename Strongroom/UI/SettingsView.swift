import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorageMode.defaultsKey) private var storageMode = StorageMode.optimized.rawValue
    @AppStorage("deleteOriginals") private var deleteOriginals = false
    @State private var showPatternChange = false
    @State private var confirmDuress = false
    @State private var confirmDelete = false
    @State private var confirmBackupOff = false

    private var backupBinding: Binding<Bool> {
        Binding(
            get: { session.snapshot.settings.backupEnabled },
            set: { enabled in
                if enabled {
                    Task { await session.setBackup(enabled: true) }
                } else {
                    confirmBackupOff = true
                }
            }
        )
    }

    private var syncStatus: String {
        guard CloudKitBackupStore.isConfigured else { return "Not available in this build" }
        guard session.snapshot.settings.backupEnabled else { return "Off" }
        switch session.syncState {
        case .idle: return session.snapshot.settings.lastBackupRevision > 0 ? "Backed up" : "Waiting"
        case .syncing: return "Backing up…"
        case .synced(let date): return "Backed up \(date.formatted(.relative(presentation: .named)))"
        case .failed(let reason): return reason
        }
    }

    private var duressBinding: Binding<Bool> {
        Binding(
            get: { session.snapshot.settings.isDuress },
            set: { enabled in
                if enabled {
                    confirmDuress = true
                } else {
                    Task { await session.setDuress(false) }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Recovery phrase") {
                        RecoveryPhraseSettingsView().environmentObject(session)
                    }
                    Button("Change pattern") { showPatternChange = true }
                } header: {
                    Text("Security")
                }

                Section {
                    NavigationLink("Shared links") { SharesView().environmentObject(session) }
                    NavigationLink("App icon") { AppIconPicker() }
                }

                Section {
                    Toggle("Back up to iCloud", isOn: backupBinding)
                        .disabled(!CloudKitBackupStore.isConfigured)
                    LabeledContent("Status") {
                        Text(syncStatus).multilineTextAlignment(.trailing)
                    }
                    Button("Back Up Now") { session.syncNow() }
                        .disabled(!session.snapshot.settings.backupEnabled || session.syncState == .syncing || !CloudKitBackupStore.isConfigured)
                } header: {
                    Text("iCloud Backup & Sync")
                } footer: {
                    Text("Everything is encrypted on this device before it goes to your private iCloud database. To restore on a new phone, or to use this vault on both iPhone and iPad, choose “Use recovery phrase” on the other device. Changes then sync both ways.")
                }

                Section {
                    Toggle("Duress vault", isOn: duressBinding)
                } footer: {
                    Text("When this vault is opened with its pattern, every other vault on this device is deleted from the device first. Encrypted iCloud backups stay, so the others can still be recovered later with their phrases.")
                }

                Section {
                    Picker("Photo & video quality", selection: $storageMode) {
                        ForEach(StorageMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Toggle("Delete originals after import", isOn: $deleteOriginals)
                } header: {
                    Text("Importing")
                } footer: {
                    Text("Optimized saves photos as HEIC (up to 4096 px) and videos as HEVC 1080p when that's smaller, and drops location data. Original keeps the exact files. Deleting originals asks for Photos access, and iOS confirms each deletion.")
                }

                Section {
                    Button("Delete this vault", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes this vault and everything in it from this device and from iCloud.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPatternChange) {
                PatternChangeView().environmentObject(session)
            }
            .alert("Make this a duress vault?", isPresented: $confirmDuress) {
                Button("Turn On", role: .destructive) { Task { await session.setDuress(true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next time this vault is opened with its pattern, all other vaults on this device will be deleted from the device. Only turn this on for a decoy vault.")
            }
            .alert("Turn off iCloud backup?", isPresented: $confirmBackupOff) {
                Button("Turn Off and Delete", role: .destructive) { Task { await session.setBackup(enabled: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The encrypted copy in iCloud is deleted. Without it, losing this phone means losing this vault, even with the recovery phrase.")
            }
            .confirmationDialog("Delete this vault?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Vault", role: .destructive) {
                    dismiss()
                    Task { await session.deleteVault() }
                }
            } message: {
                Text("Everything in it is removed from this device and from iCloud backup. This can't be undone.")
            }
        }
    }
}

/// View the phrase, or replace it with a new generated phrase or one of your own.
struct RecoveryPhraseSettingsView: View {
    @EnvironmentObject private var session: Session
    @State private var revealed = false
    @State private var customPhrase = ""
    @State private var working = false
    @State private var confirmRegenerate = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let phrase = session.snapshot.settings.recoveryPhrase {
                    if revealed {
                        PhraseGrid(phrase: phrase)
                            .listRowInsets(EdgeInsets())
                    } else {
                        Button("Show phrase") { revealed = true }
                    }
                } else {
                    Text("No recovery phrase is set.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Anyone with this phrase can open the vault, on any device with access to its backup.")
            }

            Section {
                Button("Generate a new phrase") { confirmRegenerate = true }
            } footer: {
                Text("The old phrase stops working.")
            }

            Section {
                TextField("Your own phrase", text: $customPhrase, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use this phrase") { Task { await change(customPhrase, custom: true) } }
                    .disabled(customPhrase.isEmpty)
            } header: {
                Text("Custom phrase")
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .disabled(working)
        .overlay { if working { ProgressView() } }
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Replace the recovery phrase?", isPresented: $confirmRegenerate) {
            Button("Generate") {
                Task {
                    if let phrase = try? RecoveryPhrase.generate() { await change(phrase, custom: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Write the new phrase down. The old one will no longer open this vault.")
        }
    }

    private func change(_ phrase: String, custom: Bool) async {
        working = true
        error = nil
        do {
            try await session.changeRecoveryPhrase(to: phrase, custom: custom)
            customPhrase = ""
            revealed = true
        } catch let validation as RecoveryPhrase.ValidationError {
            error = validation.message
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}

/// Draw a new pattern twice; the old pattern stops working on this device.
struct PatternChangeView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var first: Pattern?
    @State private var status = "Draw a new pattern"
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(status)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 50)
                PatternGridView(isDisabled: working) { pattern in submit(pattern) }
                    .padding(.horizontal, 40)
                    .overlay { if working { ProgressView() } }
                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Change pattern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func submit(_ pattern: Pattern) {
        do {
            try pattern.validate()
        } catch let error as Pattern.ValidationError {
            status = error.message
            return
        } catch {
            return
        }
        guard let first else {
            self.first = pattern
            status = "Draw it again to confirm"
            return
        }
        guard first == pattern else {
            self.first = nil
            status = "Patterns didn't match. Draw a new pattern."
            return
        }
        working = true
        Task {
            do {
                try await session.changePattern(to: pattern)
                dismiss()
            } catch {
                self.first = nil
                status = error.localizedDescription
            }
            working = false
        }
    }
}
