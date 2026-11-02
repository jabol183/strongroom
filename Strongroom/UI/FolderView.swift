import PhotosUI
import QuickLook
import SwiftUI

/// One folder level: subfolders, then items grouped by day. Handles importing,
/// selection, moving, exporting and deleting.
struct FolderView: View {
    let vault: Vault
    let folderID: UUID?
    @EnvironmentObject private var session: Session
    @AppStorage("deleteOriginals") private var deleteOriginals = false

    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []

    @State private var showPhotosPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showSettings = false
    @State private var showReorder = false

    @State private var viewer: ViewerRequest?
    @State private var previewURL: URL?
    @State private var noteDraft: NoteDraft?
    @State private var moveRequest: MoveRequest?
    @State private var exportPayload: ExportPayload?
    @State private var textPrompt: TextPrompt?
    @State private var promptText = ""
    @State private var pendingDelete: DeleteRequest?

    private let itemColumns = [GridItem(.adaptive(minimum: 96), spacing: 2)]
    private let folderColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    // MARK: Derived data

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var folders: [VaultIndex.Folder] {
        if isSearching {
            return session.snapshot.folders.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return session.snapshot.folders(in: folderID)
    }

    private var items: [VaultIndex.Item] {
        if isSearching {
            return session.snapshot.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return session.snapshot.items(in: folderID)
    }

    private var sections: [DaySection] { DaySection.group(items) }

    private var title: String {
        guard let folderID else { return session.isReadOnly ? "Shared Vault" : "Vault" }
        return session.snapshot.folders.first { $0.id == folderID }?.name ?? "Folder"
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            if !folders.isEmpty {
                LazyVGrid(columns: folderColumns, spacing: 12) {
                    ForEach(folders) { folder in
                        folderTile(folder)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            LazyVGrid(columns: itemColumns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            ItemCell(item: item, vault: vault, isSelecting: isSelecting, isSelected: selection.contains(item.id))
                                .onTapGesture { tap(item) }
                                .contextMenu { itemMenu(item) }
                        }
                    } header: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
        }
        .overlay {
            if folders.isEmpty && items.isEmpty && session.progress == nil {
                if isSearching {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        folderID == nil ? "Empty vault" : "Empty folder",
                        systemImage: "lock.rectangle.stack",
                        description: Text(session.isReadOnly
                            ? "Nothing has been shared here."
                            : "Tap + to add photos, videos, files or notes. Everything is encrypted as it comes in.")
                    )
                }
            }
        }
        .navigationTitle(isSelecting ? "\(selection.count) selected" : title)
        .navigationBarTitleDisplayMode(folderID == nil ? .large : .inline)
        .searchable(text: $searchText, prompt: "Search files")
        .toolbar { toolbarContent }
        .photosPicker(
            isPresented: $showPhotosPicker, selection: $pickerSelection,
            matching: .any(of: [.images, .videos]), preferredItemEncoding: .current, photoLibrary: .shared()
        )
        .onChange(of: pickerSelection) { _, picked in
            guard !picked.isEmpty else { return }
            pickerSelection = []
            Task { await session.importFromPhotos(picked, into: folderID, deleteOriginals: deleteOriginals) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await session.importFiles(urls, into: folderID) }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { capture in
                Task { await session.importCapture(capture, into: folderID) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewer) { request in
            MediaPager(
                vault: vault, items: request.items, currentID: request.startID,
                allowExport: session.canExport, allowDelete: !session.isReadOnly
            )
            .captureShield(active: !session.canExport)
            .environmentObject(session)
        }
        .quickLookPreview($previewURL)
        .sheet(item: $noteDraft) { draft in
            NoteEditor(vault: vault, draft: draft, readOnly: session.isReadOnly)
                .environmentObject(session)
        }
        .sheet(item: $moveRequest) { request in
            FolderPicker(excluding: request.excludedFolders) { destination in
                Task { await move(request, to: destination) }
            }
            .environmentObject(session)
        }
        .sheet(item: $exportPayload) { payload in
            ShareSheet(items: payload.urls)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(session)
        }
        .sheet(isPresented: $showReorder) {
            FolderReorderView(vault: vault, parentID: folderID).environmentObject(session)
        }
        .alert(textPrompt?.title ?? "", isPresented: Binding(
            get: { textPrompt != nil },
            set: { if !$0 { textPrompt = nil } }
        )) {
            TextField("Name", text: $promptText)
            Button("Save") { Task { await submitPrompt() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingDelete?.title ?? "", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { request in
            Button("Delete", role: .destructive) { Task { await delete(request) } }
        } message: { request in
            Text(request.message)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { endSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == items.count ? "Deselect All" : "Select All") {
                    selection = selection.count == items.count ? [] : Set(items.map(\.id))
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if !session.isReadOnly {
                    Button { moveRequest = MoveRequest(itemIDs: selection, folderID: nil) } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                }
                Button { Task { await export(selectedItems) } } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
                if !session.isReadOnly {
                    Spacer()
                    Button(role: .destructive) {
                        pendingDelete = .items(selection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                }
            }
        } else if session.isReadOnly {
            if folderID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { session.lock() }
                }
            }
            if session.canExport {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                        .disabled(items.isEmpty)
                }
            }
        } else {
            if folderID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { session.lock() } label: { Image(systemName: "lock") }
                        .accessibilityLabel("Lock")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showPhotosPicker = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                    if CameraPicker.isAvailable {
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    }
                    Button { showFileImporter = true } label: { Label("Files", systemImage: "doc") }
                    Button { noteDraft = NoteDraft(item: nil, folderID: folderID) } label: { Label("Note", systemImage: "note.text") }
                    Divider()
                    Button { prompt(.newFolder) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(session.progress != nil)
                .accessibilityLabel("Add")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { isSelecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        .disabled(items.isEmpty)
                    Button { showReorder = true } label: { Label("Reorder Folders", systemImage: "arrow.up.arrow.down") }
                        .disabled(session.snapshot.folders(in: folderID).count < 2)
                    Divider()
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: Folder tile

    private func folderTile(_ folder: VaultIndex.Folder) -> some View {
        NavigationLink(value: folder.id) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(folderSummary(folder)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isSelecting)
        .contextMenu {
            if !session.isReadOnly {
                Button { prompt(.renameFolder(folder.id), initial: folder.name) } label: { Label("Rename", systemImage: "pencil") }
                Button {
                    moveRequest = MoveRequest(itemIDs: [], folderID: folder.id)
                } label: { Label("Move", systemImage: "folder") }
                Button(role: .destructive) { pendingDelete = .folder(folder.id, folder.name) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func folderSummary(_ folder: VaultIndex.Folder) -> String {
        let count = session.snapshot.items(in: folder.id).count + session.snapshot.folders(in: folder.id).count
        return count == 1 ? "1 item" : "\(count) items"
    }

    // MARK: Item actions

    @ViewBuilder
    private func itemMenu(_ item: VaultIndex.Item) -> some View {
        if !session.isReadOnly {
            Button { prompt(.renameItem(item.id), initial: item.name) } label: { Label("Rename", systemImage: "pencil") }
            Button { moveRequest = MoveRequest(itemIDs: [item.id], folderID: nil) } label: { Label("Move", systemImage: "folder") }
        }
        if session.canExport {
            Button { Task { await export([item]) } } label: { Label("Export", systemImage: "square.and.arrow.up") }
        }
        if !session.isReadOnly {
            Button(role: .destructive) { pendingDelete = .items([item.id]) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var selectedItems: [VaultIndex.Item] {
        items.filter { selection.contains($0.id) }
    }

    private func tap(_ item: VaultIndex.Item) {
        if isSelecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            return
        }
        switch item.kind {
        case .photo, .video:
            let media = items.filter(\.isVisualMedia)
            viewer = ViewerRequest(items: media, startID: item.id)
        case .note:
            noteDraft = NoteDraft(item: item, folderID: item.folderID)
        case .file:
            guard session.canExport else {
                session.message = "This shared vault doesn't allow opening files, because previews can be saved outside the app."
                return
            }
            Task {
                if let url = await session.exportURLs(for: [item]).first { previewURL = url }
            }
        }
    }

    private func export(_ items: [VaultIndex.Item]) async {
        let urls = await session.exportURLs(for: items)
        if !urls.isEmpty { exportPayload = ExportPayload(urls: urls) }
    }

    private func move(_ request: MoveRequest, to destination: UUID?) async {
        if let folderID = request.folderID {
            await session.perform("Couldn't move the folder.") { try await $0.moveFolder(folderID, to: destination) }
        } else {
            await session.perform("Couldn't move.") { try await $0.move(request.itemIDs, to: destination) }
        }
        endSelection()
    }

    private func delete(_ request: DeleteRequest) async {
        switch request {
        case .items(let ids):
            for id in ids { session.thumbnails.removeObject(forKey: id as NSUUID) }
            await session.perform("Couldn't delete.") { try await $0.delete(ids) }
        case .folder(let id, _):
            await session.perform("Couldn't delete the folder.") { try await $0.deleteFolder(id) }
        }
        endSelection()
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    // MARK: Text prompts

    private func prompt(_ prompt: TextPrompt, initial: String = "") {
        promptText = initial
        textPrompt = prompt
    }

    private func submitPrompt() async {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt = textPrompt, !name.isEmpty else { return }
        textPrompt = nil
        switch prompt {
        case .newFolder:
            let parent = folderID
            await session.perform("Couldn't create the folder.") { _ = try await $0.createFolder(named: name, in: parent) }
        case .renameFolder(let id):
            await session.perform("Couldn't rename.") { try await $0.renameFolder(id, to: name) }
        case .renameItem(let id):
            await session.perform("Couldn't rename.") { try await $0.rename(id, to: name) }
        }
    }
}

// MARK: - Supporting types

struct DaySection: Identifiable {
    let id: Date
    let title: String
    let items: [VaultIndex.Item]

    static func group(_ items: [VaultIndex.Item]) -> [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.sortDate) }
        return grouped.keys.sorted(by: >).map { day in
            DaySection(
                id: day,
                title: title(for: day, calendar: calendar),
                items: grouped[day, default: []].sorted { $0.sortDate > $1.sortDate }
            )
        }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.weekday(.wide).day().month(.wide)
            : .dateTime.day().month(.wide).year()
        return day.formatted(style)
    }
}

struct ViewerRequest: Identifiable {
    let id = UUID()
    let items: [VaultIndex.Item]
    let startID: UUID
}

struct NoteDraft: Identifiable {
    let id = UUID()
    let item: VaultIndex.Item?
    let folderID: UUID?
}

struct MoveRequest: Identifiable {
    let id = UUID()
    let itemIDs: Set<UUID>
    /// Set when moving a folder rather than items.
    let folderID: UUID?

    var excludedFolders: Set<UUID> { folderID.map { [$0] } ?? [] }
}

struct ExportPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum TextPrompt: Equatable {
    case newFolder
    case renameFolder(UUID)
    case renameItem(UUID)

    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .renameFolder, .renameItem: "Rename"
        }
    }
}

enum DeleteRequest {
    case items(Set<UUID>)
    case folder(UUID, String)

    var title: String {
        switch self {
        case .items(let ids): ids.count == 1 ? "Delete this item?" : "Delete \(ids.count) items?"
        case .folder(_, let name): "Delete “\(name)”?"
        }
    }

    var message: String {
        switch self {
        case .items: "It's removed from the vault for good."
        case .folder: "The folder and everything inside it are removed from the vault for good."
        }
    }
}
