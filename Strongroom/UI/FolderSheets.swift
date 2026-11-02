import SwiftUI
import UIKit

/// Choose where to move items or a folder.
struct FolderPicker: View {
    /// Folders that can't be chosen (and their subfolders), e.g. the folder being moved.
    let excluding: Set<UUID>
    let onPick: (UUID?) -> Void
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let folder: VaultIndex.Folder
        let depth: Int
        var id: UUID { folder.id }
    }

    /// Depth-first, in each level's custom order, skipping excluded subtrees.
    private var rows: [Row] {
        var result: [Row] = []
        func walk(_ parent: UUID?, depth: Int) {
            for folder in session.snapshot.folders(in: parent) where !excluding.contains(folder.id) {
                result.append(Row(folder: folder, depth: depth))
                walk(folder.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Button { pick(nil) } label: {
                    Label("Vault", systemImage: "lock.rectangle.stack")
                }
                ForEach(rows) { row in
                    Button { pick(row.folder.id) } label: {
                        Label(row.folder.name, systemImage: "folder")
                            .padding(.leading, CGFloat(row.depth) * 20)
                    }
                }
            }
            .navigationTitle("Move To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func pick(_ id: UUID?) {
        onPick(id)
        dismiss()
    }
}

/// Drag to set the custom order of folders at one level.
struct FolderReorderView: View {
    let vault: Vault
    let parentID: UUID?
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [VaultIndex.Folder] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders) { folder in
                    Label(folder.name, systemImage: "folder")
                }
                .onMove { folders.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let ids = folders.map(\.id)
                        let parent = parentID
                        Task {
                            await session.perform("Couldn't reorder.") { try await $0.reorderFolders(in: parent, orderedIDs: ids) }
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { folders = session.snapshot.folders(in: parentID) }
        }
    }
}

/// The system share sheet for decrypted temporary files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
