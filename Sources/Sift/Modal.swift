import SwiftUI

/// A confirm / single-input modal: title, description, one text field, and a
/// primary action button (red for destructive) that stays disabled until the
/// field passes `isEnabled`. Used for destructive confirms ("type confirm") and
/// for capturing a value (e.g. a Slack thread link to watch).
struct SiftModalConfig: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var fieldPrompt: String
    var actionLabel: String
    var destructive: Bool
    var isEnabled: (String) -> Bool
    var onSubmit: (String) -> Void
}

struct SiftModal: View {
    let config: SiftModalConfig
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var enabled: Bool { config.isEnabled(text) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 12) {
                Text(config.title).font(.headline)
                Text(config.message)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(config.fieldPrompt, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if enabled { submit() } }

                HStack(spacing: 8) {
                    Spacer()
                    SiftButton("Cancel", variant: .secondary, action: onClose)
                        .keyboardShortcut(.cancelAction)
                    SiftButton(config.actionLabel,
                               variant: config.destructive ? .danger : .primary,
                               enabled: enabled, action: submit)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.themeCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            )
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard enabled else { return }
        config.onSubmit(text)
        onClose()
    }
}

extension View {
    /// Presents a `SiftModal` over this view while `config` is non-nil.
    func siftModal(_ config: Binding<SiftModalConfig?>) -> some View {
        overlay {
            if let cfg = config.wrappedValue {
                SiftModal(config: cfg) { config.wrappedValue = nil }
                    .id(cfg.id)   // reset the field's @State between presentations
            }
        }
    }
}
