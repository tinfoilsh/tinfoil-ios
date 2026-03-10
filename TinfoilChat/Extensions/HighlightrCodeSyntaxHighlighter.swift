import Highlightr
import MarkdownUI
import SwiftUI

private final class HighlightCache {
    static let shared = HighlightCache()
    private let cache = NSCache<NSString, NSAttributedString>()

    init() {
        cache.countLimit = 200
    }

    func get(key: String) -> NSAttributedString? {
        cache.object(forKey: key as NSString)
    }

    func set(_ value: NSAttributedString, key: String) {
        cache.setObject(value, forKey: key as NSString)
    }
}

struct HighlightrCodeSyntaxHighlighter: CodeSyntaxHighlighter {
  private let highlightr: Highlightr
  private let themeName: String

  init(theme: String = "xcode") {
    self.highlightr = Highlightr()!
    self.highlightr.setTheme(to: theme)
    self.themeName = theme
  }

  func highlightCode(_ content: String, language: String?) -> Text {
    guard let language = language,
          content.count <= Constants.Rendering.maxSyntaxHighlightCharacters
    else {
      return Text(content)
    }

    let cacheKey = "\(themeName)_\(language)_\(content.hashValue)"
    if let cached = HighlightCache.shared.get(key: cacheKey) {
        return Text(AttributedString(cached))
    }

    guard let highlighted = highlightr.highlight(content, as: language) else {
        return Text(content)
    }

    HighlightCache.shared.set(highlighted, key: cacheKey)
    return Text(AttributedString(highlighted))
  }
}

extension CodeSyntaxHighlighter where Self == HighlightrCodeSyntaxHighlighter {
  static func highlightr(theme: String = "xcode") -> Self {
    HighlightrCodeSyntaxHighlighter(theme: theme)
  }
}
