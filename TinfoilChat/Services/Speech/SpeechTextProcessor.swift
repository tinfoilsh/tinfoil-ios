import Foundation
import NaturalLanguage

enum SpeechTextProcessor {
    private static let lineBreakPattern = #"(?i)<br\s*/?>"#
    private static let footnoteDefinitionPattern = #"(?m)^ {0,3}\[\^[^\]\n]+\]:[^\n]*(?:\n(?:\t| {4})[^\n]*)*"#
    private static let footnoteReferencePattern = #"\[\^[^\]\n]+\]"#
    private static let mathPattern = #"(?s)\$\$(.*?)\$\$|(?<![\\$])\$(?![\s$])([^\n$]*[^\s$])\$(?![-+]?\d)"#
    private static let automaticURLPrefixes = ["https://", "http://"]
    // Both alternatives are escaped constants, never expressions supplied by a message.
    private static let reasoningTags = try! NSRegularExpression(
        pattern: [Constants.Speech.thinkingOpenTag, Constants.Speech.thinkingCloseTag]
            .map { "(" + NSRegularExpression.escapedPattern(for: $0) + ")" }
            .joined(separator: "|"),
        options: .caseInsensitive
    )

    static func source(for message: Message) -> String {
        if !message.content.isEmpty { return message.content }
        return (message.segments ?? []).compactMap { segment in
            if case .text(let text) = segment { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func canRead(_ message: Message) -> Bool {
        message.role == .assistant && !message.isStreaming && !message.isThinking
            && message.streamError == nil && message.isError != true
            && !removingReasoning(source(for: message)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func prepare(_ source: String) throws -> String {
        guard source.utf16.count <= Constants.Speech.maxTextCharacters else { throw SpeechError.tooLong }
        let markdown = removingReasoning(source)
            .replacingOccurrences(of: lineBreakPattern, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: footnoteDefinitionPattern, with: "", options: .regularExpression)
        let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
        let links = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var text = ""
        var blockIdentity: Int?
        for (link, range) in parsed.runs[\.link] {
            if let link {
                let label = String(parsed[range].characters)
                let citation = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if label == link.absoluteString
                    || (!citation.isEmpty && citation.allSatisfy(\.isNumber)) { continue }
            }
            for run in parsed[range].runs {
                let inline = run.inlinePresentationIntent ?? []
                guard run.imageURL == nil, inline.intersection([.inlineHTML, .blockHTML]).isEmpty else { continue }
                let components = run.presentationIntent?.components ?? []
                if components.contains(where: { component in
                    switch component.kind {
                    case .codeBlock, .thematicBreak: return true
                    default: return false
                    }
                }) { continue }
                let identity = components.first(where: { component in
                    switch component.kind {
                    case .paragraph, .header, .tableCell: return true
                    default: return false
                    }
                })?.identity ?? components.first(where: { component in
                    if case .listItem = component.kind { return true }
                    return false
                })?.identity
                if identity != blockIdentity, !text.isEmpty { text += "\n" }
                blockIdentity = identity
                var prose = String(parsed[run.range].characters)
                if !inline.contains(.code) {
                    prose = prose.replacingOccurrences(of: footnoteReferencePattern, with: "", options: .regularExpression)
                }
                if link == nil, !inline.contains(.code) {
                    for match in links.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)).reversed() {
                        if let range = Range(match.range, in: prose),
                           automaticURLPrefixes.contains(where: { prose[range].lowercased().hasPrefix($0) }) {
                            prose.removeSubrange(range)
                        }
                    }
                }
                text += prose
            }
        }

        // Foundation's Markdown parser does not expose math or footnote nodes.
        // Format extraction stays structural; these extensions operate on prose.
        let math = try NSRegularExpression(pattern: mathPattern)
        for match in math.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let contentRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            if let whole = Range(match.range, in: text), let content = Range(contentRange, in: text) {
                text.replaceSubrange(whole, with: String(text[content]))
            }
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func removingReasoning(_ source: String) -> String {
        let input = source as NSString
        let result = NSMutableString(capacity: input.length)
        var cursor = 0
        var depth = 0
        for match in reasoningTags.matches(in: source, range: NSRange(location: 0, length: input.length)) {
            let tag = input.substring(with: match.range)
            let isOpening = match.range(at: 1).location != NSNotFound
            if depth == 0 {
                result.append(input.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                if !isOpening { result.append(tag) }
            }
            depth = isOpening ? depth + 1 : max(0, depth - 1)
            cursor = NSMaxRange(match.range)
        }
        if depth == 0 {
            result.append(input.substring(from: cursor))
        }
        return result as String
    }

    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        var cursor = text.startIndex
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            sentences.append(String(text[cursor..<range.upperBound]))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { sentences.append(String(text[cursor...])) }
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for sentence in sentences {
            let characters = Array(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
            var start = 0
            while characters.count - start > Constants.Speech.maxChunkCharacters {
                flush()
                var end = start + Constants.Speech.maxChunkCharacters
                for index in stride(from: end, to: start + Constants.Speech.targetChunkCharacters, by: -1) {
                    if characters[index].isWhitespace { end = index; break }
                }
                let chunk = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { chunks.append(chunk) }
                start = end
            }
            let remainder = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { continue }
            if current.count + remainder.count + (current.isEmpty ? 0 : 1) > Constants.Speech.maxChunkCharacters { flush() }
            current = current.isEmpty ? remainder : current + " " + remainder
            if current.count >= Constants.Speech.targetChunkCharacters { flush() }
        }
        flush()
        return chunks
    }
}
