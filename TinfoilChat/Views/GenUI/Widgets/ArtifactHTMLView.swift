//
//  ArtifactHTMLView.swift
//  TinfoilChat
//
//  Renders a model-authored HTML artifact under the same limits as the
//  webapp's artifact sandbox (tinfoilsh/tinfoil-webapp-sandbox).

import SwiftUI
import WebKit

/// Runs an HTML artifact's own scripts while keeping the page away from the
/// app and the network:
/// - an in-memory data store per view, so nothing persists or is shared;
/// - no script message handlers, so the page cannot call into the app;
/// - a content rule list that blocks every load except HTTPS images, fonts,
///   and media;
/// - no navigation away from the artifact. Tapped links open outside the app
///   through `GenUIURLOpener`, and every other navigation is cancelled.
///
/// The page is loaded only after the content rules are installed. If they
/// fail to compile, `onUnavailable` is called and nothing is loaded.
struct ArtifactHTMLView: UIViewRepresentable {
    let html: String
    let onUnavailable: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = context.coordinator.contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // A link preview would load the target page outside this sandbox.
        webView.allowsLinkPreview = false
        context.coordinator.load(html, into: webView, onUnavailable: onUnavailable)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, into: webView, onUnavailable: onUnavailable)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let contentController = WKUserContentController()
        private var hasInstalledRules = false
        private var loadedHTML: String?
        private var loadTask: Task<Void, Never>?

        func load(_ html: String, into webView: WKWebView, onUnavailable: @escaping @MainActor () -> Void) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            loadTask?.cancel()
            loadTask = Task { [weak self, weak webView] in
                do {
                    let rules = try await ArtifactContentRules.compiled()
                    guard !Task.isCancelled, let self, let webView else { return }
                    if !self.hasInstalledRules {
                        self.contentController.add(rules)
                        self.hasInstalledRules = true
                    }
                    webView.loadHTMLString(html, baseURL: Constants.Artifacts.baseURL)
                } catch {
                    guard !Task.isCancelled else { return }
                    onUnavailable()
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            guard let targetFrame = navigationAction.targetFrame else {
                openTappedLink(navigationAction)
                return .cancel
            }
            if targetFrame.isMainFrame {
                if ArtifactNavigation.isArtifactDocument(url) { return .allow }
                openTappedLink(navigationAction)
                return .cancel
            }
            return ArtifactNavigation.isInlineFrameDocument(url) ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            openTappedLink(navigationAction)
            return nil
        }

        /// Relative links resolve against the artifact's unreachable origin,
        /// so only links to other hosts are worth opening.
        private func openTappedLink(_ navigationAction: WKNavigationAction) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  url.host != Constants.Artifacts.baseURL.host else { return }
            GenUIURLOpener.open(url.absoluteString)
        }
    }
}

enum ArtifactNavigation {
    /// The artifact itself, including jumps to anchors within it.
    static func isArtifactDocument(_ url: URL) -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.fragment = nil
        return components.url == Constants.Artifacts.baseURL
    }

    /// Frames whose document comes from the artifact itself (`srcdoc`,
    /// `about:blank`, or a `data:` URL) rather than from the network.
    static func isInlineFrameDocument(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "about" || scheme == "data"
    }
}

enum ArtifactContentRules {
    enum CompilationError: Error {
        case noRuleList
    }

    @MainActor private static var cachedRules: WKContentRuleList?

    /// Rules are compiled once per launch and shared by every artifact view.
    @MainActor
    static func compiled() async throws -> WKContentRuleList {
        if let cachedRules {
            return cachedRules
        }
        let rules = try await compile()
        cachedRules = rules
        return rules
    }

    /// Later rules take precedence: block everything, then let the artifact
    /// document, inline data, and HTTPS images, fonts, and media through.
    static func encodedRules() throws -> String {
        let escapedBaseURL = Constants.Artifacts.baseURL.absoluteString
            .replacingOccurrences(of: ".", with: "\\.")
        let rules: [[String: Any]] = [
            rule(urlFilter: ".*", action: "block"),
            rule(urlFilter: "^\(escapedBaseURL)", action: "ignore-previous-rules"),
            rule(urlFilter: "^data:", action: "ignore-previous-rules"),
            rule(urlFilter: "^blob:", action: "ignore-previous-rules"),
            rule(urlFilter: "^about:", action: "ignore-previous-rules"),
            rule(
                urlFilter: "^https://",
                resourceTypes: Constants.Artifacts.remoteResourceTypes,
                action: "ignore-previous-rules"
            ),
        ]
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func rule(
        urlFilter: String,
        resourceTypes: [String]? = nil,
        action: String
    ) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": urlFilter]
        if let resourceTypes {
            trigger["resource-type"] = resourceTypes
        }
        return ["trigger": trigger, "action": ["type": action]]
    }

    @MainActor
    private static func compile() async throws -> WKContentRuleList {
        let encoded = try encodedRules()
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: Constants.Artifacts.contentRuleListIdentifier,
                encodedContentRuleList: encoded
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: error ?? CompilationError.noRuleList)
                }
            }
        }
    }
}
