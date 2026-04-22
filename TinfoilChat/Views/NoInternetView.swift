import SwiftUI

struct NoInternetView: View {
    let retryAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: Constants.UI.initFailedContentSpacing) {
                Spacer()

                Image(systemName: "wifi.slash")
                    .font(.system(size: Constants.UI.initFailedIconSize))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    Text("No Internet Connection")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)

                    Text("Please check your internet connection and try again.")
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

#Preview {
    NoInternetView {
        // Preview action
    }
} 