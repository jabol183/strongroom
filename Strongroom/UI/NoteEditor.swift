import SwiftUI

/// Create or edit an encrypted text note.
struct NoteEditor: View {
    let vault: Vault
    let draft: NoteDraft
    var readOnly = false
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Title", text: $title)
                    .font(.title2.bold())
                    .padding()
                    .disabled(readOnly)
                Divider()
                TextEditor(text: $text)
                    .focused($bodyFocused)
                    .padding(.horizontal, 12)
                    .disabled(readOnly || !loaded)
            }
            .navigationTitle(draft.item == nil ? "New Note" : "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "Close" : "Cancel") { dismiss() }
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .disabled(!loaded)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard !loaded else { return }
        if let item = draft.item {
            title = item.name
            if let data = try? await vault.contents(of: item) {
                text = String(decoding: data, as: UTF8.self)
            }
        } else {
            bodyFocused = true
        }
        loaded = true
    }

    private func save() async {
        let (id, folderID, title, text) = (draft.item?.id, draft.folderID, title, text)
        await session.perform("Couldn't save the note.") {
            _ = try await $0.saveNote(id: id, title: title, text: text, folderID: folderID)
        }
        dismiss()
    }
}
