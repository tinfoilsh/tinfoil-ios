import SwiftUI

struct SafeguardFlagBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: SafeguardsStore
    let chatId: String
    let onOpenSettings: () -> Void

    private var title: String {
        store.usesExamples
            ? "Local preview: this chat was flagged by a safeguard model."
            : "This chat was flagged by a safeguard model."
    }

    var body: some View {
        if store.isFlagged(chatId) {
            HStack(alignment: .top, spacing: Constants.Safeguards.contentSpacing) {
                Image(systemName: "flag.fill")
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Constants.Safeguards.Banner.textSpacing) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(Constants.Safeguards.Banner.message)
                        .font(.caption)
                    if store.usesExamples {
                        Text("This is a simulated flag. Your account is unaffected.")
                            .font(.caption)
                    }
                    Button(action: onOpenSettings) {
                        Text("Learn more in Settings → Safeguards")
                            .font(.caption.weight(.medium))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Constants.Safeguards.Banner.textSpacing)
                    .accessibleHitTarget()
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color(hex: colorScheme == .dark
                ? Constants.Safeguards.Banner.darkTextColorHex
                : Constants.Safeguards.Banner.lightTextColorHex))
            .padding(Constants.Safeguards.contentSpacing)
            .background(
                Color.red.opacity(Constants.Safeguards.Banner.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: Constants.Safeguards.Banner.cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Constants.Safeguards.Banner.cornerRadius)
                    .strokeBorder(
                        Color.red.opacity(Constants.Safeguards.Banner.borderOpacity),
                        lineWidth: Constants.Safeguards.Banner.borderWidth
                    )
            }
            .padding(.horizontal, Constants.Safeguards.contentSpacing)
            .padding(.bottom, Constants.Safeguards.contentSpacing)
            .onAppear {
                AccessibilityAnnouncer.announce("\(title) \(Constants.Safeguards.Banner.message)")
            }
        }
    }
}
