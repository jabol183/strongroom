import SwiftUI

/// A square grid cell: decrypted thumbnail (cached until lock) plus kind badges.
struct ItemCell: View {
    let item: VaultIndex.Item
    let vault: Vault
    var isSelecting = false
    var isSelected = false
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
                    placeholder
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.3))
                        .padding(6)
                }
            }
            .opacity(isSelecting && !isSelected ? 0.75 : 1)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .task(id: item.thumbnailName) { await loadThumbnail() }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2)
            if item.kind == .file, let ext = item.fileExtension {
                Text(ext.uppercased()).font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var caption: some View {
        switch item.kind {
        case .video:
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                Spacer()
                if let duration = item.duration { Text(Self.format(duration)) }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(5)
        case .file, .note:
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
        case .photo:
            EmptyView()
        }
    }

    private var symbol: String {
        switch item.kind {
        case .photo: "photo"
        case .video: "video"
        case .note: "note.text"
        case .file: "doc"
        }
    }

    private var accessibilityText: String {
        switch item.kind {
        case .photo: "Photo, \(item.name)"
        case .video: "Video, \(item.name)"
        case .note: "Note, \(item.name)"
        case .file: "File, \(item.name)"
        }
    }

    private func loadThumbnail() async {
        guard item.thumbnailName != nil else { return }
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

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
