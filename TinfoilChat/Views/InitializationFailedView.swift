import SwiftUI

/// Fallback screen shown when the app fails to fetch its bootstrap
/// configuration (e.g. TLS handshake failure, verifier mismatch). Mirrors
/// the layout and button style of `NoInternetView` and the onboarding
/// flow so every "dead end" surface in the app looks consistent.
struct InitializationFailedView: View {
    let errorMessage: String
    let retryAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: Constants.UI.initFailedContentSpacing) {
                Spacer()

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Constants.UI.initFailedIconSize))
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    Text("Failed to Initialize")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)

                    Text(errorMessage)
                        .font(.system(size: 17))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                }

                Spacer()

                Button(action: retryAction) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .medium))
                        Text("Try Again")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(colorScheme == .dark ? Color.white : Color.black)
                    )
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 24)

                Spacer()
                    .frame(height: 80)
            }
            .padding()
        }
    }
}

#Preview("Dark") {
    InitializationFailedView(
        errorMessage: "A TLS error caused the secure connection to fail.",
        retryAction: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    InitializationFailedView(
        errorMessage: "A TLS error caused the secure connection to fail.",
        retryAction: {}
    )
    .preferredColorScheme(.light)
}
