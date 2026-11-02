import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorageMode.defaultsKey) private var storageMode = StorageMode.optimized.rawValue
    @AppStorage("deleteOriginals") private var deleteOriginals = false

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
