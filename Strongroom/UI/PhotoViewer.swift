import SwiftUI

/// Decrypts one photo into memory only; nothing is written to disk in the clear.
struct PhotoViewer: View {
    let item: VaultIndex.Item
    let vault: Vault
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var confirmingDelete = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Label("Couldn't open this item", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title)
                }
                .accessibilityLabel("Close")
                Spacer()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash.circle.fill").font(.title)
                }
                .accessibilityLabel("Delete")
            }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .padding()
        }
        .confirmationDialog("Delete this photo from the vault?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await session.delete(item)
                    dismiss()
                }
            }
        }
        .task {
            do {
                let data = try await vault.contents(of: item)
                image = UIImage(data: data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}
