import SwiftUI

/// A small filled button for the action a status message offers, as
/// recovering a key or loading chats again.
struct StatusActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color)
            .cornerRadius(6)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
