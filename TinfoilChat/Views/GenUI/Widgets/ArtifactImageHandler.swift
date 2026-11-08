import Foundation
import WebKit

@MainActor
final class ArtifactImageHandler: NSObject, WKURLSchemeHandler {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var startedRequests = 0

    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        startedRequests = 0
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard startedRequests < Constants.Artifacts.imageRequestLimit,
              (urlSchemeTask.request.httpMethod ?? "GET").uppercased() == "GET",
              let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              components.scheme == Constants.Artifacts.imageScheme,
              components.host == "fetch",
              let query = components.queryItems, query.count == 1,
              query[0].name == "url", let imageURL = query[0].value,
              imageURL.utf8.count <= Constants.Metadata.imageURLLengthLimit else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        startedRequests += 1
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            do {
                let data = try await LinkMetadataService.shared.image(for: imageURL)
                guard let self, !Task.isCancelled, self.tasks[id] != nil else { return }
                defer { self.tasks[id] = nil }
                urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: Constants.Metadata.imageContentType, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard let self, !Task.isCancelled, self.tasks[id] != nil else { return }
                self.tasks[id] = nil
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    static var script: String {
        #"""
        (() => {
          const scheme = '\#(Constants.Artifacts.imageScheme):';
          const selector = 'img, image, video[poster], input[type="image"], picture source';
          const xlinkNamespace = 'http://www.w3.org/1999/xlink';
          const attributes = new Set(['src', 'srcset', 'href', 'poster', 'type']);
          function rewrite(element) {
            if (element.hasAttribute('srcset')) element.removeAttribute('srcset');
            if (element.localName === 'source') return;
            const attribute = element.localName === 'video' ? 'poster' : element.localName === 'image' ? 'href' : 'src';
            const source = element.getAttribute(attribute) || (element.localName === 'image' ? element.getAttributeNS(xlinkNamespace, 'href') : null);
            if (!source || /^(data:|blob:)/i.test(source) || source.startsWith(scheme)) return;
            if (element.localName === 'image') element.removeAttributeNS(xlinkNamespace, 'href');
            element.setAttribute(attribute, scheme + '//fetch?url=' + encodeURIComponent(source));
          }
          function visit(node) {
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            if (node.matches(selector)) rewrite(node);
            node.querySelectorAll(selector).forEach(rewrite);
          }
          new MutationObserver(changes => {
            for (const change of changes) {
              if (change.type === 'attributes') {
                if (attributes.has(change.attributeName)) visit(change.target);
              }
              else change.addedNodes.forEach(visit);
            }
          }).observe(document, {subtree: true, childList: true, attributes: true});
          if (document.documentElement) visit(document.documentElement);
        })();
        """#
    }
}
