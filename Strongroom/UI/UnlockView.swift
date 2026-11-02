import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var session: Session
    @State private var showRecovery = false

    private var mode: (title: String, symbol: String) {
        switch session.state {
        case .confirmingNew: ("Confirm new vault", "plus.circle")
        case .choosingPattern(_, nil): ("Draw a new pattern", "arrow.triangle.2.circlepath")
        case .choosingPattern: ("Draw it again", "arrow.triangle.2.circlepath")
        default: ("Draw your pattern", "lock.fill")
        }
    }

    private var isLocked: Bool {
        if case .locked = session.state { return true }
        return false
    }

    private var isConfirming: Bool {
        if case .confirmingNew = session.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: mode.symbol)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)
            Text(mode.title)
                .font(.title2.bold())
            Text(session.message ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .padding(.horizontal)

            PatternGridView(isDisabled: session.isBusy) { session.submit($0) }
                .padding(.horizontal, 40)
                .overlay {
                    if session.isBusy { ProgressView("Unlocking…") }
                }

            if isConfirming {
                Button("Cancel", role: .cancel) { session.cancelCreate() }
            } else if isLocked {
                HStack(spacing: 24) {
                    Button("Use recovery phrase") { showRecovery = true }
                    JoinSharedButton()
                }
                .font(.subheadline)
            }
            Spacer()
        }
        .sensoryFeedback(.warning, trigger: session.message) { _, new in new != nil }
        .sheet(isPresented: $showRecovery) {
            RecoveryEntryView().environmentObject(session)
        }
    }
}
