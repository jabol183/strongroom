import SwiftUI
import UIKit

/// Disguise the app's home-screen icon. Every icon still opens the pattern screen.
struct AppIconPicker: View {
    struct Choice: Identifiable {
        let id: String?       // alternate icon name; nil = the default icon
        let title: String
        let preview: String   // image set with a preview of the icon
    }

    static let choices: [Choice] = [
        Choice(id: nil, title: "Strongroom", preview: "IconPreview"),
        Choice(id: "AppIcon-Calculator", title: "Calculator", preview: "IconPreview-Calculator"),
        Choice(id: "AppIcon-Printer", title: "Printer", preview: "IconPreview-Printer"),
        Choice(id: "AppIcon-Notes", title: "Notes", preview: "IconPreview-Notes"),
        Choice(id: "AppIcon-Weather", title: "Weather", preview: "IconPreview-Weather"),
        Choice(id: "AppIcon-Compass", title: "Compass", preview: "IconPreview-Compass"),
        Choice(id: "AppIcon-Clock", title: "Clock", preview: "IconPreview-Clock"),
        Choice(id: "AppIcon-Scanner", title: "Scanner", preview: "IconPreview-Scanner"),
    ]

    @State private var current = UIApplication.shared.alternateIconName
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 20)], spacing: 24) {
                ForEach(Self.choices) { choice in
                    Button { select(choice) } label: {
                        VStack(spacing: 8) {
                            Image(choice.preview)
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(current == choice.id ? Color.accentColor : .clear, lineWidth: 3)
                                        .padding(-4)
                                }
                            Text(choice.title).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(current == choice.id ? .isSelected : [])
                }
            }
            .padding()
            Text(error ?? "The app's name under the icon stays “Strongroom”. iOS shows a short notice when the icon changes.")
                .font(.footnote)
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
                .padding(.horizontal)
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ choice: Choice) {
        guard UIApplication.shared.supportsAlternateIcons, choice.id != current else { return }
        UIApplication.shared.setAlternateIconName(choice.id) { error in
            Task { @MainActor in
                if let error {
                    self.error = error.localizedDescription
                } else {
                    current = choice.id
                    self.error = nil
                }
            }
        }
    }
}
