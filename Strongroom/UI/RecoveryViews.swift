import SwiftUI

/// Shown once after a vault is created: the generated phrase, or a phrase of the user's own.
struct RecoveryPhraseSetupView: View {
    @EnvironmentObject private var session: Session
    @State private var useCustom = false
    @State private var customPhrase = ""
    @State private var acknowledged = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This phrase is the only way back in if you forget your pattern or lose this phone. Write it down and keep it somewhere safe. Nobody, including the app's maker, can reset it.")
                        .foregroundStyle(.secondary)

                    if useCustom {
                        TextField("Your own phrase", text: $customPhrase, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...4)
                            .padding()
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        Text("At least \(RecoveryPhrase.minimumCustomWords) words. The generated phrase is stronger unless yours is long and unpredictable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let phrase = session.snapshot.settings.recoveryPhrase {
                        PhraseGrid(phrase: phrase)
                    }

                    Button(useCustom ? "Use the generated phrase instead" : "Use my own phrase") {
                        useCustom.toggle()
                    }
                    .font(.subheadline)

                    Toggle("I've written down my recovery phrase", isOn: $acknowledged)
                }
                .padding()
            }
            .navigationTitle("Recovery phrase")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        saving = true
                        Task {
                            _ = await session.finishPhraseSetup(customPhrase: useCustom ? customPhrase : nil)
                            saving = false
                        }
                    }
                    .disabled(!acknowledged || saving || (useCustom && customPhrase.isEmpty))
                }
            }
            .overlay { if saving { ProgressView() } }
            .alert("Notice", isPresented: Binding(
                get: { session.message != nil },
                set: { if !$0 { session.message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.message ?? "")
            }
        }
        .interactiveDismissDisabled()
    }
}

/// Numbered words, large and legible for writing down.
struct PhraseGrid: View {
    let phrase: String

    var body: some View {
        let words = phrase.split(separator: " ").map(String.init)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            ForEach(Array(words.enumerated()), id: \.offset) { offset, word in
                HStack(spacing: 6) {
                    Text("\(offset + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(word).font(.body.monospaced().weight(.medium))
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovery phrase: \(phrase)")
    }
}

/// From the unlock screen: type the phrase to open a vault (and set a new pattern).
struct RecoveryEntryView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recovery phrase", text: $phrase, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                } footer: {
                    Text(error ?? "Type the words separated by spaces. Capital letters and extra spaces don't matter.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Use recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recover") { Task { await recover() } }
                        .disabled(working || RecoveryPhrase.normalize(phrase).isEmpty)
                }
            }
            .overlay { if working { ProgressView("Checking…") } }
        }
    }

    private func recover() async {
        working = true
        error = nil
        let ok = await session.recover(phrase: phrase)
        working = false
        if ok {
            dismiss()
        } else {
            error = session.message
            session.message = nil
        }
    }
}
