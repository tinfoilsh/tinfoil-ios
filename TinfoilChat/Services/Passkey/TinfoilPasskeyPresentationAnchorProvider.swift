import AuthenticationServices
import TinfoilPasskeyKit
import UIKit

@MainActor
final class TinfoilPasskeyPresentationAnchorProvider: PasskeyPresentationAnchorProviding {
    typealias Resolver = @MainActor () -> UIWindow?

    private let resolver: Resolver
    private let fallbackAnchor = UIWindow(frame: .zero)

    init(resolver: @escaping Resolver = TinfoilPasskeyPresentationAnchorProvider.activeWindow) {
        self.resolver = resolver
    }

    var presentationAnchor: ASPresentationAnchor {
        resolver() ?? fallbackAnchor
    }

    @discardableResult
    func requirePresentationAnchor() throws -> ASPresentationAnchor {
        guard let anchor = resolver() else {
            throw PasskeyError.presentationAnchorUnavailable
        }
        return anchor
    }

    static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.compactMap { scene in
            scene.windows.first(where: \.isKeyWindow)
                ?? scene.windows.first(where: { !$0.isHidden && $0.alpha > 0 })
        }.first
    }
}
