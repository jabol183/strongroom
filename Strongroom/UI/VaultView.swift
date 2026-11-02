import PhotosUI
import SwiftUI

struct VaultView: View {
    let vault: Vault
    @EnvironmentObject private var session: Session
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var viewing: VaultIndex.Item?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(session.items) { item in
                        ThumbnailCell(item: item, vault: vault)
                            .onTapGesture { viewing = item }
                    }
                }
            }
            .overlay {
                if session.items.isEmpty && session.importProgress == nil {
                    ContentUnavailableView(
                        "Empty vault",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Tap + to import photos. They're encrypted as they come in. Delete the originals from Photos afterwards.")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let progress = session.importProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("Encrypting \(progress.done) of \(progress.total)")
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
            .navigationTitle("Vault")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { session.lock() } label: { Image(systemName: "lock") }
                        .accessibilityLabel("Lock")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerSelection, matching: .images) {
                        Image(systemName: "plus")
                    }
                    .disabled(session.importProgress != nil)
                    .accessibilityLabel("Import photos")
                }
            }
            .onChange(of: pickerSelection) { _, selection in
                guard !selection.isEmpty else { return }
                Task {
                    await session.importPhotos(selection)
                    pickerSelection = []
                }
            }
            .fullScreenCover(item: $viewing) { item in
                PhotoViewer(item: item, vault: vault)
                    .environmentObject(session)
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
}

struct ThumbnailCell: View {
    let item: VaultIndex.Item
    let vault: Vault
    @EnvironmentObject private var session: Session
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: item.id) {
                let key = item.id as NSUUID
                if let cached = session.thumbnails.object(forKey: key) {
                    image = cached
                    return
                }
                guard let data = try? await vault.thumbnail(for: item),
                      let decoded = UIImage(data: data) else { return }
                session.thumbnails.setObject(decoded, forKey: key)
                image = decoded
            }
    }
}
