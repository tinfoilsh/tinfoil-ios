import Highlightr
import MarkdownUI
import SwiftUI

private final class AttributedStringBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private final class HighlightCache {
    static let shared = HighlightCache()
    private let cache = NSCache<NSString, AttributedStringBox>()

    init() {
        cache.countLimit = 200
    }

    func get(key: String) -> AttributedStringBox? {
        cache.object(forKey: key as NSString)
    }

    func set(_ value: AttributedString, key: String) {
        cache.setObject(AttributedStringBox(value), forKey: key as NSString)
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
        return Text(cached.value)
    }

    guard let highlighted = highlightr.highlight(content, as: language) else {
        return Text(content)
    }

    let attributed = AttributedString(highlighted)
    HighlightCache.shared.set(attributed, key: cacheKey)
    return Text(attributed)
  }
}

extension CodeSyntaxHighlighter where Self == HighlightrCodeSyntaxHighlighter {
  static func highlightr(theme: String = "xcode") -> Self {
    HighlightrCodeSyntaxHighlighter(theme: theme)
  }
}
