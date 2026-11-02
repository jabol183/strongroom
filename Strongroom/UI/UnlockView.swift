import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var session: Session

    private var isConfirming: Bool {
        if case .confirmingNew = session.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: isConfirming ? "plus.circle" : "lock.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)
            Text(isConfirming ? "Confirm new vault" : "Draw your pattern")
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
            }
            Spacer()
        }
        .sensoryFeedback(.warning, trigger: session.message) { _, new in new != nil }
    }
}
