import SwiftUI
import UIKit

// MARK: - Recipient

struct JoinSharedButton: View {
    @EnvironmentObject private var session: Session
    @State private var showJoin = false

    var body: some View {
        Button("Join shared vault") { showJoin = true }
            .sheet(isPresented: $showJoin) {
                JoinShareView().environmentObject(session)
            }
    }
}

struct JoinShareView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Share phrase", text: $phrase, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                } footer: {
                    Text(error ?? "Enter the 9 words you were given. A shared vault opens read-only and is removed from this device when you close it.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Join shared vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { Task { await join() } }
                        .disabled(working || RecoveryPhrase.normalize(phrase).isEmpty)
                }
            }
            .overlay {
                if working {
                    if let progress = session.progress, progress.total > 1 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                            Text("Downloading…")
                        }
                        .padding(40)
                    } else {
                        ProgressView("Opening…")
                    }
                }
            }
        }
    }

    private func join() async {
        working = true
        error = nil
        let ok = await session.joinShare(phrase: phrase)
        working = false
        if ok {
            dismiss()
        } else {
            error = session.message
            session.message = nil
        }
    }
}

/// Hides content while the screen is being recorded or mirrored, and notes screenshots.
/// iOS can't block screenshots, so for no-export shares this discourages rather than prevents.
struct CaptureShield: ViewModifier {
    let active: Bool
    @State private var isCaptured = UIScreen.main.isCaptured
    @State private var screenshotNotice = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && isCaptured {
                    ZStack {
                        Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                        Label("Hidden while the screen is recorded", systemImage: "eye.slash")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                isCaptured = UIScreen.main.isCaptured
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                if active { screenshotNotice = true }
            }
            .alert("Screenshot taken", isPresented: $screenshotNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The owner of this shared vault asked that its contents not be saved.")
            }
    }
}

extension View {
    func captureShield(active: Bool) -> some View {
        modifier(CaptureShield(active: active))
    }
}

// MARK: - Sharer

struct SharesView: View {
    @EnvironmentObject private var session: Session
    @State private var showCreate = false

    var body: some View {
        List {
            Section {
                Button { showCreate = true } label: {
                    Label("Share This Vault", systemImage: "person.2.badge.key")
                }
                .disabled(!CloudKitBackupStore.isConfigured)
            } footer: {
                Text("Uploads an encrypted copy of everything currently in this vault. Whoever has the share phrase can open it read-only on their own device, until it expires, runs out of opens, or you revoke it. Later changes to your vault aren't shared.")
            }

            if !session.snapshot.settings.shares.isEmpty {
                Section("Active shares") {
                    ForEach(session.snapshot.settings.shares) { share in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(share.itemCount) items · \(share.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            Text(describe(share)).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Revoke", role: .destructive) {
                                Task { await session.revokeShare(share) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Shared links")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreate) {
            CreateShareView().environmentObject(session)
        }
    }

    private func describe(_ share: VaultIndex.ShareRecord) -> String {
        var parts: [String] = []
        if let expiresAt = share.expiresAt {
            parts.append(expiresAt < Date() ? "Expired" : "Expires \(expiresAt.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("No expiry")
        }
        parts.append(share.maxOpens.map { $0 == 1 ? "1 open" : "\($0) opens" } ?? "Unlimited opens")
        parts.append(share.allowExport ? "Export allowed" : "No export")
        return parts.joined(separator: " · ")
    }
}

struct CreateShareView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var maxOpens = 1
    @State private var expiry: TimeInterval = 86_400
    @State private var allowExport = false
    @State private var working = false
    @State private var phrase: String?
    @State private var error: String?

    private let openChoices = [1, 3, 10, 0]
    private let expiryChoices: [(String, TimeInterval)] = [("1 hour", 3_600), ("1 day", 86_400), ("1 week", 604_800), ("Never", 0)]

    var body: some View {
        NavigationStack {
            Form {
                if let phrase {
                    Section {
                        PhraseGrid(phrase: phrase).listRowInsets(EdgeInsets())
                        ShareLink(item: phrase) { Label("Send phrase", systemImage: "square.and.arrow.up") }
                    } header: {
                        Text("Share phrase")
                    } footer: {
                        Text("Anyone with these words can open the share, so send them over a channel you trust. This is the only time they're shown.")
                    }
                } else {
                    Section {
                        Picker("Can be opened", selection: $maxOpens) {
                            ForEach(openChoices, id: \.self) { n in
                                Text(n == 0 ? "Unlimited" : (n == 1 ? "Once" : "\(n) times")).tag(n)
                            }
                        }
                        Picker("Expires after", selection: $expiry) {
                            ForEach(expiryChoices.indices, id: \.self) { i in
                                Text(expiryChoices[i].0).tag(expiryChoices[i].1)
                            }
                        }
                        Toggle("Allow saving and exporting", isOn: $allowExport)
                    } footer: {
                        Text(error ?? "Limits and export settings are enforced by the app. Someone determined could still photograph the screen.")
                            .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle("Share This Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phrase == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }.disabled(working)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .overlay { if working { ProgressView("Encrypting and uploading…") } }
            .interactiveDismissDisabled(working || phrase != nil)
        }
    }

    private func create() async {
        working = true
        error = nil
        let policy = SharePolicy(
            maxOpens: maxOpens == 0 ? nil : maxOpens,
            expiresAfter: expiry == 0 ? nil : expiry,
            allowExport: allowExport
        )
        do {
            phrase = try await session.createShare(policy: policy)
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}
