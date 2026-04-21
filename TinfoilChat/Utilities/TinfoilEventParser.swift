import Foundation

/// Payload shipped inside a `<tinfoil-event>...</tinfoil-event>` marker.
///
/// The router emits these inline with the model's assistant text when
/// the caller opts into the marker stream via the `X-Tinfoil-Events`
/// request header. Strict OpenAI SDKs render the surrounding tags as
/// literal text; this app parses and strips them so the same
/// `webSearchState` / `URLFetchState` UI keeps working after the
/// legacy top-level `web_search_call` SSE records were removed from
/// the router.
struct TinfoilWebSearchCallEvent: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case inProgress = "in_progress"
        case searching
        case completed
        case failed
        case blocked
    }

    struct Action: Decodable, Sendable {
        let type: String?
        let query: String?
        let url: String?
    }

    struct ErrorInfo: Decodable, Sendable {
        let code: String?
    }

    let type: String
    let itemId: String?
    let status: Status
    let action: Action?
    let error: ErrorInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case itemId = "item_id"
        case status
        case action
        case error
    }
}

/// Streaming parser that extracts `<tinfoil-event>...</tinfoil-event>`
/// markers from arbitrary content chunks and returns the visible text
/// with every complete marker removed. The parser is chunk-tolerant:
/// markers may be split across any byte boundary (inside the opening
/// tag, the JSON body, or the closing tag).
///
/// The router pairs this with the `X-Tinfoil-Events: web_search` opt-in
/// header. When a client does not opt in no markers are emitted, the
/// parser is a pure pass-through.
struct TinfoilEventParser {
    private static let openTag = "<tinfoil-event>"
    private static let closeTag = "</tinfoil-event>"

    /// Holds bytes the parser has not yet classified: either a potential
    /// prefix of the opening tag (held back in case the next chunk
    /// completes the match) or the inside of a marker whose closing
    /// tag has not yet landed.
    private var buffer: String = ""
    private var insideMarker: Bool = false

    /// One `consume` result: the visible text for this chunk (with
    /// completed markers removed) plus zero or more decoded events.
    struct Result {
        var text: String
        var events: [TinfoilWebSearchCallEvent]
    }

    /// Feed a content chunk through the parser. Chunks must arrive in
    /// order; calling `consume` on interleaved chunks from different
    /// streams will corrupt the parser state.
    mutating func consume(_ chunk: String) -> Result {
        buffer += chunk
        var text = ""
        var events: [TinfoilWebSearchCallEvent] = []

        while !buffer.isEmpty {
            if !insideMarker {
                if let openRange = buffer.range(of: Self.openTag) {
                    text += buffer[..<openRange.lowerBound]
                    buffer = String(buffer[openRange.upperBound...])
                    insideMarker = true
                    continue
                }
                // No full open tag yet. Emit everything except any
                // trailing bytes that could still grow into a real
                // `<tinfoil-event>` opener on the next chunk.
                let hold = openTagPrefixSuffixLength(buffer)
                let split = buffer.index(buffer.endIndex, offsetBy: -hold)
                text += buffer[..<split]
                buffer = String(buffer[split...])
                break
            }

            guard let closeRange = buffer.range(of: Self.closeTag) else {
                // The payload has not fully landed yet; wait for more.
                break
            }
            let payload = String(buffer[..<closeRange.lowerBound])
            buffer = String(buffer[closeRange.upperBound...])
            insideMarker = false
            if let decoded = Self.decode(payload) {
                events.append(decoded)
            }
        }

        return Result(text: text, events: events)
    }

    /// Drain any bytes the parser is still holding. Call at stream end
    /// so unterminated marker bodies and held-back open-tag prefixes
    /// are not silently dropped. The returned text is a best-effort
    /// surface: the opening `<tinfoil-event>` is never leaked, but an
    /// unterminated JSON body will flow through as plain text so the
    /// UI has something to show if the router mid-stream errored out.
    mutating func flush() -> String {
        let tail = buffer
        buffer = ""
        insideMarker = false
        return tail
    }

    /// Returns the length of the longest suffix of `s` that is a
    /// proper prefix of the opening tag. Used to hold back trailing
    /// bytes like `<tinfoil-` that might still grow into a marker
    /// opener when the next chunk arrives.
    private func openTagPrefixSuffixLength(_ s: String) -> Int {
        let max = Swift.min(s.count, Self.openTag.count - 1)
        guard max > 0 else { return 0 }
        var len = max
        while len > 0 {
            let suffix = s.suffix(len)
            if Self.openTag.hasPrefix(suffix) {
                return len
            }
            len -= 1
        }
        return 0
    }

    private static func decode(_ payload: String) -> TinfoilWebSearchCallEvent? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(TinfoilWebSearchCallEvent.self, from: data)
        } catch {
            return nil
        }
    }
}
