import UIKit

/// Copies secrets, such as the chat key or backup codes, to the clipboard of
/// this device only, where they expire, so Universal Clipboard does not hand
/// them to the account's other devices and they do not linger.
enum SensitiveClipboard {
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(Constants.CloudSync.clipboardExpirationSeconds),
            ]
        )
    }
}
