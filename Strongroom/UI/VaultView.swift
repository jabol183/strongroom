import SwiftUI

/// Root of an unlocked vault: folder navigation plus app-wide progress and alerts.
struct VaultView: View {
    let vault: Vault
    @EnvironmentObject private var session: Session

    var body: some View {
        NavigationStack {
            FolderView(vault: vault, folderID: nil)
                .navigationDestination(for: UUID.self) { folderID in
                    FolderView(vault: vault, folderID: folderID)
                }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = session.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("\(progress.label) \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                        .font(.footnote)
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .alert("Notice", isPresented: Binding(
            get: { session.message != nil },
            set: { if !$0 { session.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.message ?? "")
        }
    }
}
