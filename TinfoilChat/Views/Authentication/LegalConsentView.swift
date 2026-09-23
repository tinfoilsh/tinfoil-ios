import SwiftUI

struct LegalConsentView: View {
    @Binding var isAccepted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Legal.consentSpacing) {
            Button {
                isAccepted.toggle()
            } label: {
                Image(systemName: isAccepted ? "checkmark.square.fill" : "square")
                    .font(.system(size: Constants.Legal.checkboxSize))
                    .frame(
                        width: Constants.Legal.checkboxHitTargetSize,
                        height: Constants.Legal.checkboxHitTargetSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.adaptiveAccent)
            .accessibilityLabel(Constants.Legal.consentAccessibilityLabel)
            .accessibilityValue(isAccepted ? "Checked" : "Unchecked")
            .accessibilityAddTraits(isAccepted ? .isSelected : [])

            Text("I have read and agree to the [Terms of Service](\(Constants.Legal.termsOfServiceURL.absoluteString)) and [Privacy Policy](\(Constants.Legal.privacyPolicyURL.absoluteString)).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .tint(Color.adaptiveAccent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Constants.Legal.checkboxHitTargetSize, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
