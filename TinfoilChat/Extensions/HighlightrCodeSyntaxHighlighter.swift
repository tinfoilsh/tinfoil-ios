import Highlightr
import MarkdownUI
import SwiftUI

struct HighlightrCodeSyntaxHighlighter: CodeSyntaxHighlighter {
  private let highlightr: Highlightr

  init(theme: String = "xcode") {
    self.highlightr = Highlightr()!
    self.highlightr.setTheme(to: theme)
  }

  func highlightCode(_ content: String, language: String?) -> Text {
    guard let language = language,
          let highlighted = highlightr.highlight(content, as: language)
    else {
      return Text(content)
    }

    return Text(AttributedString(highlighted))
  }
}

extension CodeSyntaxHighlighter where Self == HighlightrCodeSyntaxHighlighter {
  static func highlightr(theme: String = "xcode") -> Self {
    HighlightrCodeSyntaxHighlighter(theme: theme)
  }
}
