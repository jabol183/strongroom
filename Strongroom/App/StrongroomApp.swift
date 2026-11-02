import SwiftUI

@main
struct StrongroomApp: App {
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                // Covers content before iOS snapshots the app for the app switcher.
                .overlay {
                    if scenePhase != .active { PrivacyCover() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.lock() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        switch session.state {
        case .unlocked(let vault):
            VaultView(vault: vault)
        case .locked, .unlocking, .confirmingNew:
            UnlockView()
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }
}
