import Foundation
import OpenAI

enum WebSearchHistory {
    private struct Action {
        let name: String
        let arguments: String
        let sources: [WebSearchSource]
    }

    private static func actions(for message: Message) -> [Action] {
        guard message.role == .assistant else { return [] }
        var actions: [Action] = []
        func addSearch(query: String?, status: String?, sources: [WebSearchSource]) {
            guard status == WebSearchStatus.completed.rawValue, let query, !query.isEmpty,
                  let arguments = json(["query": query]) else { return }
            actions.append(Action(name: Constants.WebSearchHistory.searchTool, arguments: arguments, sources: sources))
        }
        func addFetch(url: String, status: String?, sources: [WebSearchSource]) {
            guard status == URLFetchStatus.completed.rawValue,
                  let arguments = json(["urls": [url]]) else { return }
            actions.append(Action(name: Constants.WebSearchHistory.fetchTool, arguments: arguments, sources: sources.filter { $0.url == url }))
        }
        let timeline = message.buildSyncTimeline() ?? []
        let hasWebTimeline = timeline.contains {
            let type = $0.objectValue?["type"]?.stringValue
            return type == "web_search" || type == "url_fetches"
        }
        if hasWebTimeline {
            for block in timeline {
                guard let fields = block.objectValue else { continue }
                if fields["type"]?.stringValue == "web_search", let state = fields["state"]?.objectValue {
                    addSearch(query: state["query"]?.stringValue, status: state["status"]?.stringValue,
                              sources: state["sources"]?.arrayValue?.compactMap(WebSearchSource.fromTimeline) ?? [])
                }
                if fields["type"]?.stringValue == "url_fetches" {
                    for raw in fields["fetches"]?.arrayValue ?? [] {
                        guard let fetch = raw.objectValue, let url = fetch["url"]?.stringValue else { continue }
                        addFetch(url: url, status: fetch["status"]?.stringValue,
                                 sources: fetch["sources"]?.arrayValue?.compactMap(WebSearchSource.fromTimeline) ?? [])
                    }
                }
            }
        } else {
            if let searches = message.webSearches, !searches.isEmpty {
                for search in searches {
                    addSearch(query: search.query, status: search.status.rawValue, sources: search.sources ?? [])
                }
            } else if let search = message.webSearchState {
                addSearch(query: search.query, status: search.status.rawValue, sources: search.sources)
            }
            for fetch in message.urlFetches {
                addFetch(url: fetch.url, status: fetch.status.rawValue, sources: fetch.sources ?? [])
            }
        }
        return actions
    }

    static func messages(for message: Message, messageIndex: Int) -> [ChatQuery.ChatCompletionMessageParam] {
        actions(for: message).enumerated().flatMap { (index, action) -> [ChatQuery.ChatCompletionMessageParam] in
            let id = "\(Constants.WebSearchHistory.callIDPrefix)\(messageIndex)_\(index)"
            let sources = action.sources.compactMap { source -> [String: String]? in
                guard let snippet = source.snippet, !snippet.isEmpty,
                      source.url.lowercased().hasPrefix("https://") || source.url.lowercased().hasPrefix("http://") else { return nil }
                return ["url": source.url, "title": source.title, "snippet": snippet]
            }
            guard !sources.isEmpty,
                  let output = json(["note": Constants.WebSearchHistory.evidenceNote, "sources": sources]) else { return [] }
            return [
                .assistant(.init(content: nil, reasoningContent: "", toolCalls: [
                    .init(id: id, function: .init(arguments: action.arguments, name: action.name))
                ])),
                .tool(.init(content: .textContent(output), toolCallId: id))
            ]
        }
    }

    static func serializedLength(_ messages: [ChatQuery.ChatCompletionMessageParam]) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(messages), let text = String(data: data, encoding: .utf8) else { return Int.max }
        return text.utf16.count
    }

    private static func json(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
