import UIKit

/// Opens links that replies, sources and fetched pages name: web pages and
/// mail only. Any other scheme, such as an app's or a phone number, could
/// act in another app on what a model or a page wrote.
enum LinkOpener {
    private static let schemes: Set<String> = ["https", "http", "mailto"]

    static func canOpen(_ url: URL) -> Bool {
        url.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }

    @MainActor
    static func open(_ url: URL) {
        guard canOpen(url) else { return }
        UIApplication.shared.open(url)
    }

    @MainActor
    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        open(url)
    }
}
