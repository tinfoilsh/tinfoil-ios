import Foundation

/// Builds what the views show from what the harness sends: a message from
/// its blocks, and a chat from its summary.
enum ChatViewMapping {
    private static let searchTool = "web_search"
    private static let fetchTool = "web_fetch"

    private static func isShownTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == searchTool || name == fetchTool || name.hasPrefix(harnessWidgetPrefix)
    }

    /// A message as the view shows it, with the latest summary of each
    /// thinking block's reasoning. A reply thinks only in its last block:
    /// reasoning ends once the reply goes on to text or a tool call.
    /// shownAs is the id the message's row was first shown with, when a turn
    /// replaced the message's own.
    static func message(_ wire: HarnessMessage, streaming: Bool = false, summaries: [String: String] = [:], shownAs id: String? = nil) -> Message {
        let role: MessageRole = wire.role == .user ? .user : .assistant
        var message = Message(id: id ?? wire.id, role: role, content: wire.content ?? "", timestamp: ChatAccessCache.date(of: wire.createdAt) ?? .distantPast)
        message.modelDisplayName = wire.modelDisplayName
        message.isError = wire.isError
        message.annotations = wire.annotations?.compactMap { annotation in
            guard let citation = annotation.urlCitation else { return nil }
            return Annotation(type: "url_citation", url_citation: URLCitation(title: citation.title, url: citation.url, start_index: citation.startIndex, end_index: citation.endIndex))
        }
        message.attachments = wire.attachments?.map(attachment) ?? []
        guard role == .assistant else { return message }

        let blocks = wire.timeline ?? []
        var segments: [MessageSegment] = []
        var searches: [WebSearchInstance] = []
        var fetches: [URLFetchState] = []
        var toolCalls: [GenUIToolCall] = []
        var timeline: [JSONValue] = []
        var thoughts = ""
        var text = ""
        var thinkingSeconds = 0.0
        var thinking = false
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            switch block._type {
            case .thinking:
                let content = block.content ?? ""
                let isThinking = streaming && last && block.complete != true
                thoughts += (thoughts.isEmpty ? "" : "\n\n") + content
                if let duration = block.duration { thinkingSeconds += duration }
                thinking = thinking || isThinking
                segments.append(.thinking(content: content, isThinking: isThinking, duration: block.duration, startedAt: block.startedAt, endedAt: block.endedAt))
                timeline.append(timelineBlock(block, summary: summaries[block.id]))
            case .content:
                let content = block.content ?? ""
                text += content
                segments.append(.text(content))
                timeline.append(timelineBlock(block))
            case .toolCall:
                guard isShownTool(block.name) else { continue }
                let toolCallId = block.toolCallId ?? block.id
                let status = toolStatus(block, streaming: streaming)
                if block.name == searchTool {
                    searches.append(WebSearchInstance(
                        id: block.id, query: block.display?.query, status: status == .completed ? .completed : status == .failed ? .failed : .searching,
                        sources: block.display?.sources.map(source), reason: nil, startedAt: block.startedAt, endedAt: block.endedAt
                    ))
                    segments.append(.webSearch(searchId: block.id))
                } else if block.name == fetchTool {
                    let urls = fetchedUrls(block)
                    guard !urls.isEmpty else { continue }
                    let unread = unreadUrls(block.result)
                    for (position, url) in urls.enumerated() {
                        let id = position == 0 ? toolCallId : "\(toolCallId)-\(position)"
                        let fetchStatus: URLFetchStatus = status == .completed ? (unread.contains(url) ? .failed : .completed) : status == .failed ? .failed : .fetching
                        fetches.append(URLFetchState(id: id, url: url, status: fetchStatus, sources: block.display?.sources.filter { $0.url == url }.map(source), startedAt: block.startedAt, endedAt: block.endedAt))
                        segments.append(.urlFetch(fetchId: id))
                    }
                } else {
                    toolCalls.append(GenUIToolCall(id: toolCallId, name: block.name ?? "", arguments: block.arguments ?? ""))
                    segments.append(.toolCall(toolCallId: toolCallId))
                }
                timeline.append(timelineBlock(block))
            }
        }
        message.content = text
        message.thoughts = thoughts.isEmpty ? nil : thoughts
        message.isThinking = thinking
        message.isStreaming = streaming
        // A reply still thinking has thought for no settled time yet.
        message.generationTimeSeconds = !thinking && thinkingSeconds > 0 ? thinkingSeconds : nil
        message.thinkingDuration = thinkingSeconds > 0 ? thinkingSeconds : nil
        message.segments = segments
        message.webSearches = searches.isEmpty ? nil : searches
        message.webSearchState = searches.last.map { WebSearchState(query: $0.query, status: $0.status, sources: $0.sources ?? [], reason: nil) }
        message.urlFetches = fetches
        message.toolCalls = toolCalls
        message.timeline = timeline
        return message
    }

    private enum ToolStatus { case running, completed, failed }

    /// A web search or page fetch shows what the harness reports of it. A
    /// call it reports nothing of yet runs while its reply streams; one
    /// still running once the reply stopped was cut off.
    private static func toolStatus(_ block: TimelineBlock, streaming: Bool) -> ToolStatus {
        switch block.display?.status {
        case .completed: return .completed
        case .failed: return .failed
        case .running, nil: return streaming ? .running : .failed
        }
    }

    private static func source(_ source: Components.Schemas.ToolDisplay.SourcesPayloadPayload) -> WebSearchSource {
        WebSearchSource(id: source.url, title: source.title, url: source.url, snippet: source.snippet)
    }

    /// The pages a fetch reads, as its arguments name them; while they
    /// stream, the page the harness reports, if it reported one yet.
    private static func fetchedUrls(_ block: TimelineBlock) -> [String] {
        if let data = block.arguments?.data(using: .utf8), let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var urls = (arguments["urls"] as? [Any])?.compactMap { $0 as? String } ?? []
            if let url = arguments["url"] as? String { urls.append(url) }
            urls = urls.filter { !$0.isEmpty }
            if !urls.isEmpty { return urls }
        }
        return block.display?.url.map { [$0] } ?? []
    }

    /// The pages a fetch's result lists as not read.
    private static func unreadUrls(_ result: Components.Schemas.Json?) -> Set<String> {
        guard let object = result?.value as? [String: Any], let failed = object["failed"] as? [Any] else { return [] }
        return Set(failed.compactMap { ($0 as? [String: Any])?["url"] as? String })
    }

    private static func timelineBlock(_ block: TimelineBlock, summary: String? = nil) -> JSONValue {
        var value = JSONValue(any: (try? block.jsonObject()) ?? [:])
        if let summary, var object = value.objectValue {
            object["summary"] = .string(summary)
            value = .object(object)
        }
        return value
    }

    static func attachment(_ view: Components.Schemas.AttachmentView) -> Attachment {
        attachment(
            id: view.id, kind: view.kind, fileName: view.fileName, mimeType: view.mimeType, size: view.size,
            thumbnail: view.thumbnail, textContent: view.textContent, description: view.description
        )
    }

    /// An upload also carries the copy of an image the chat sends models.
    static func attachment(_ uploaded: Components.Schemas.Attachment) -> Attachment {
        var attachment = attachment(
            id: uploaded.id, kind: uploaded.kind, fileName: uploaded.fileName, mimeType: uploaded.mimeType, size: uploaded.size,
            thumbnail: uploaded.thumbnail, textContent: uploaded.textContent, description: uploaded.description
        )
        attachment.base64 = uploaded.base64
        return attachment
    }

    /// An attachment the harness holds is complete as the view shows it.
    private static func attachment(
        id: String, kind: Components.Schemas.AttachmentKind, fileName: String, mimeType: String, size: Int?,
        thumbnail: String?, textContent: String?, description: String?
    ) -> Attachment {
        var attachment = Attachment(
            id: id,
            type: kind == .image ? .image : .document,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: Int64(size ?? 0)
        )
        attachment.thumbnailBase64 = thumbnail
        attachment.textContent = textContent
        attachment.description = description
        attachment.processingState = .completed
        return attachment
    }

    /// A queued turn's attachments that can be shown. One the chat already
    /// holds is named by its id alone.
    static func queuedAttachments(_ item: QueueItem) -> [Attachment] {
        item.attachments.compactMap { queued in
            guard let id = queued.id, let kind = queued.kind, let fileName = queued.fileName else { return nil }
            return attachment(Components.Schemas.AttachmentView(id: id, kind: kind, fileName: fileName, mimeType: queued.mimeType ?? "", size: queued.size, thumbnail: queued.thumbnail))
        }
    }

    /// A chat waiting for its generated title shows the default one.
    static func title(_ summary: ThreadSummary) -> String {
        summary.titleState == .placeholder && summary.title == Constants.Harness.placeholderTitle ? Chat.defaultTitle : summary.title
    }

    /// A chat as the view shows it, from its summary and the messages shown.
    static func chat(_ summary: ThreadSummary, messages: [Message] = [], local: Bool, temporary: Bool = false, presetId: String? = nil) -> Chat {
        var chat = Chat(id: summary.id, title: title(summary), messages: messages, createdAt: summary.createdAt.flatMap(ChatAccessCache.date(of:)) ?? Date())
        chat.titleState = summary.titleState == .manual ? .manual : summary.titleState == .generated ? .generated : .placeholder
        chat.isLocalOnly = local
        chat.isTemporary = temporary
        chat.projectId = summary.projectId
        chat.promptPresetId = presetId
        chat.webSearchEnabled = summary.webSearchEnabled
        chat.updatedAt = summary.updatedAt.flatMap(ChatAccessCache.date(of:))
        chat.activityAt = ChatAccessCache.date(of: summary.activityAt)
        chat.flagged = summary.flagged ?? false
        chat.pinned = summary.pinned
        chat.model = summary.model
        chat.messageCount = summary.messageCount
        chat.activeRun = summary.activeRun.map { ActiveRun(runId: $0.runId, expiresAt: $0.expiresAt, instance: $0.instance) }
        chat.contextUsage = summary.contextUsage.map { ContextUsage(percentage: $0.percentage, usedTokens: $0.usedTokens, limitTokens: $0.limitTokens) }
        return chat
    }
}

/// A hint that a reply may be streaming, until the run's deadline.
struct ActiveRun: Equatable, Sendable {
    let runId: String
    let expiresAt: String
    let instance: String
}
