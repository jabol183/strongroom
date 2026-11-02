import AVKit
import SwiftUI

/// Full-screen, swipeable viewer for photos and videos. Photos decrypt into memory;
/// videos decrypt to a temporary file that is removed when the page goes away (and on lock).
struct MediaPager: View {
    let vault: Vault
    let items: [VaultIndex.Item]
    @State var currentID: UUID
    var allowExport = true
    var allowDelete = true

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var exportPayload: ExportPayload?
    @State private var chromeHidden = false

    private var current: VaultIndex.Item? { items.first { $0.id == currentID } }

    var body: some View {
        TabView(selection: $currentID) {
            ForEach(items) { item in
                MediaPage(vault: vault, item: item, isCurrent: item.id == currentID)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black.ignoresSafeArea())
        .onTapGesture { withAnimation { chromeHidden.toggle() } }
        .overlay(alignment: .top) {
            if !chromeHidden { topBar }
        }
        .statusBarHidden(chromeHidden)
        .confirmationDialog("Delete from the vault?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteCurrent() } }
        }
        .sheet(item: $exportPayload) { payload in
            ShareSheet(items: payload.urls)
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Close")
            Spacer()
            if let current {
                Text(current.name).font(.footnote).lineLimit(1)
            }
            Spacer()
            if allowExport, let current {
                Button {
                    Task {
                        let urls = await session.exportURLs(for: [current])
                        if !urls.isEmpty { exportPayload = ExportPayload(urls: urls) }
                    }
                } label: { Image(systemName: "square.and.arrow.up.circle.fill") }
                    .accessibilityLabel("Export")
            }
            if allowDelete {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash.circle.fill")
                }
                .accessibilityLabel("Delete")
            }
        }
        .font(.title)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.white)
        .padding()
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func deleteCurrent() async {
        guard let current else { return }
        session.thumbnails.removeObject(forKey: current.id as NSUUID)
        await session.perform("Couldn't delete.") { try await $0.delete([current.id]) }
        dismiss()
    }
}

private struct MediaPage: View {
    let vault: Vault
    let item: VaultIndex.Item
    let isCurrent: Bool

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var tempURL: URL?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = max(1, min(lastScale * $0.magnification, 6)) }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5 }
                        lastScale = scale
                    }
            } else if let player {
                VideoPlayer(player: player)
            } else if failed {
                Label("Couldn't open this item", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isCurrent) {
            guard isCurrent else {
                player?.pause()
                return
            }
            await load()
        }
        .onDisappear(perform: cleanUp)
    }

    private func load() async {
        guard image == nil, player == nil else { return }
        do {
            switch item.kind {
            case .photo:
                let data = try await vault.contents(of: item)
                let decoded = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
                image = decoded
                failed = decoded == nil
            case .video:
                let url = try await vault.decryptToTemporaryFile(item)
                tempURL = url
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            case .file, .note:
                failed = true
            }
        } catch {
            failed = true
        }
    }

    private func cleanUp() {
        player?.pause()
        player = nil
        image = nil
        if let tempURL { TempFiles.remove(tempURL) }
        tempURL = nil
    }
}
