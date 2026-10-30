//
//  MessageView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import Textual
import SwiftMath
import UIKit

func shouldShowStreamError(message: Message) -> Bool {
    message.role == .assistant && message.streamError != nil
}

enum AssistantMessageActionPolicy {
    static func canRegenerate(
        isLastMessage: Bool,
        canGenerateInCurrentChat: Bool,
        isLoading: Bool,
        messageIndex: Int,
        isRateLimitError: Bool,
        isHourlyLimitError: Bool
    ) -> Bool {
        isLastMessage
            && canGenerateInCurrentChat
            && !isLoading
            && messageIndex > 0
            && (!isRateLimitError || isHourlyLimitError)
    }

    enum StreamErrorRetry: Equatable {
        case continueResponse
        case regenerate
    }

    /// The retry offered on a failed response's error box. A response with
    /// something to resume is continued; otherwise it is generated again.
    static func streamErrorRetry(
        canRegenerate: Bool,
        hasPartialResponse: Bool
    ) -> StreamErrorRetry? {
        guard canRegenerate else { return nil }
        return hasPartialResponse ? .continueResponse : .regenerate
    }
}

private struct MessageSecurityMetadataView: View {
    let modelDisplayName: String?
    let isDarkMode: Bool

    private var trimmedModelDisplayName: String? {
        guard let name = modelDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    var body: some View {
        HStack(spacing: 4) {
            if let trimmedModelDisplayName {
                Text(trimmedModelDisplayName)
                    .font(.caption2)
                Text("·")
                    .font(.caption2)
            }
            HStack(spacing: 3) {
                Image(systemName: "lock")
                    .font(.system(size: Constants.MessageMetadata.iconSize))
                Text("Encrypted")
                    .font(.system(size: Constants.MessageMetadata.encryptedFontSize))
            }
        }
        .foregroundStyle(isDarkMode ? Color.white.opacity(0.5) : Color.black.opacity(0.5))
        .accessibilityElement(children: .combine)
    }
}

struct MessageView: View {
    let message: Message
    let isDarkMode: Bool
    let isLastMessage: Bool
    let isLoading: Bool
    let messageIndex: Int
    let stepExpansion: WorkStepExpansion
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel
    @State private var showLongMessageSheet = false
    @State private var selectLongMessageOnPresentation = false
    @State private var userTextSelectionRequest = 0
    @State private var showRawContentModal = false
    @State private var showSourcesSheet = false
    @State private var showShareSheet = false

    private var isAnyMessageSheetPresented: Bool {
        showLongMessageSheet || showRawContentModal || showSourcesSheet || showShareSheet
    }

    private var inlineAssistantTextSelectionEnabled: Bool {
        guard !isRenderingStream else { return false }
        return message.content.count <= Constants.Rendering.maxInlineSelectionCharacters
    }

    private var isRenderingStream: Bool {
        isLoading && isLastMessage
    }

    private var canUseUserMessageActions: Bool {
        viewModel.canGenerateInCurrentChat
            && !viewModel.isLoading
            && viewModel.messageEditSession == nil
            && viewModel.pendingAttachments.isEmpty
    }

    private var canShowUserMessageMenu: Bool {
        !viewModel.isCurrentChatSafeguardFlagged
            && !viewModel.isLoading
            && viewModel.messageEditSession == nil
    }

    private func forkFromHere() {
        Task { await viewModel.forkChat(throughMessageIndex: messageIndex) }
    }

    private var canShareAssistantMessage: Bool {
        isLastMessage && !viewModel.isLoading
    }

    private var showsAssistantMoreMenu: Bool {
        canShareAssistantMessage || viewModel.canForkMessage(at: messageIndex)
    }

    private var canRegenerateAssistantResponse: Bool {
        AssistantMessageActionPolicy.canRegenerate(
            isLastMessage: isLastMessage,
            canGenerateInCurrentChat: viewModel.canGenerateInCurrentChat,
            isLoading: viewModel.isLoading,
            messageIndex: messageIndex,
            isRateLimitError: message.isRateLimitError,
            isHourlyLimitError: message.isHourlyLimitError
        )
    }

    private var hasVisibleStreamError: Bool {
        shouldShowStreamError(message: message)
    }

    private var streamErrorRetry: AssistantMessageActionPolicy.StreamErrorRetry? {
        guard hasVisibleStreamError else { return nil }
        return AssistantMessageActionPolicy.streamErrorRetry(
            canRegenerate: canRegenerateAssistantResponse,
            hasPartialResponse: message.hasContinuableResponse
        )
    }

    /// resends says the turn never reached the chat service, so retrying
    /// sends the message again.
    private func streamErrorRetryButton(resends: Bool) -> ErrorMessageView.Retry? {
        switch streamErrorRetry {
        case .continueResponse:
            return ErrorMessageView.Retry(
                label: Constants.MessageActions.continueLabel,
                systemImage: Constants.MessageActions.continueSystemImage
            ) {
                viewModel.continueLastResponse()
            }
        case .regenerate:
            return ErrorMessageView.Retry(
                label: resends ? Constants.MessageActions.resendLabel : Constants.MessageActions.tryAgainLabel,
                systemImage: Constants.MessageActions.tryAgainSystemImage
            ) {
                viewModel.retryLastResponse()
            }
        case nil:
            return nil
        }
    }

    /// An empty failed response needs no action row: its error box already
    /// offers to generate it again.
    private var showsAssistantActionSection: Bool {
        !isRenderingStream && message.hasVisibleAssistantContent
    }

    /// Secondary actions for assistant messages live behind an ellipsis so the
    /// inline row stays short enough for narrow screens.
    private var assistantMoreMenu: some View {
        Menu {
            if canShareAssistantMessage {
                Button {
                    showShareSheet = true
                } label: {
                    Label(
                        Constants.MessageActions.shareLabel,
                        systemImage: Constants.MessageActions.shareSystemImage
                    )
                }
            }

            if viewModel.canForkMessage(at: messageIndex) {
                Button(action: forkFromHere) {
                    Label(
                        Constants.ChatFork.actionLabel,
                        systemImage: Constants.ChatFork.actionSystemImage
                    )
                }
            }
        } label: {
            Image(systemName: Constants.MessageActions.moreSystemImage)
                .font(.system(size: Constants.MessageActions.iconSize))
                .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5))
                .frame(
                    width: Constants.MessageActions.buttonSize,
                    height: Constants.MessageActions.buttonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Constants.MessageActions.moreLabel)
        .accessibleHitTarget()
    }

    /// Runs of adjacent segments collapsed for inline rendering. Adjacent
    /// searches/fetches are merged into one row so long tool-call chains
    /// don't stack N full-height pills in the chat, and a run of two or
    /// more trace rows (thinking, searches, fetches) collapses further
    /// into a single `.work` row summarizing the whole run.
    enum InlineSegmentRun {
        case text(String, isTrailing: Bool)
        case step(WorkStep)
        case toolCall(GenUIToolCall)
        case work(WorkRun)
    }

    struct IdentifiedInlineSegmentRun: Identifiable {
        let id: String
        let run: InlineSegmentRun
    }

    static func inlineSegmentRuns(from segments: [MessageSegment], message: Message) -> [IdentifiedInlineSegmentRun] {
        let lastTextIndex: Int? = {
            for i in segments.indices.reversed() {
                if case .text(let text) = segments[i],
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return i }
            }
            return nil
        }()

        var runs: [IdentifiedInlineSegmentRun] = []
        // Trace steps accumulated since the last visible text / tool call.
        var work: [WorkStep] = []
        var workStartIndex: Int?
        var searchBuffer: [WebSearchInstance] = []
        var fetchBuffer: [URLFetchState] = []

        func flushSearches() {
            guard !searchBuffer.isEmpty else { return }
            work.append(.webSearches(searchBuffer))
            searchBuffer.removeAll()
        }
        func flushFetches() {
            guard !fetchBuffer.isEmpty else { return }
            work.append(.urlFetches(fetchBuffer))
            fetchBuffer.removeAll()
        }
        func flushWork() {
            flushSearches()
            flushFetches()
            defer {
                work.removeAll()
                workStartIndex = nil
            }
            guard let startIndex = workStartIndex, let first = work.first else { return }
            // A lone step and the run it grows into share an id, so the row
            // stays open as steps join it.
            runs.append(IdentifiedInlineSegmentRun(
                id: "work:\(startIndex):\(first.id)",
                run: work.count > 1 ? .work(WorkRun(steps: work)) : .step(first)
            ))
        }
        func noteWorkStart(_ index: Int) {
            if workStartIndex == nil { workStartIndex = index }
        }

        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                flushWork()
                runs.append(IdentifiedInlineSegmentRun(
                    id: "text:\(index)",
                    run: .text(text, isTrailing: index == lastTextIndex)
                ))
            case .thinking(let content, let isThinking, let duration, let startedAt):
                // A closed, empty thought renders nothing and must not split a run.
                guard isThinking || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                flushSearches()
                flushFetches()
                noteWorkStart(index)
                work.append(.thinking(
                    content: content,
                    isThinking: isThinking,
                    duration: duration,
                    startedAt: startedAt
                ))
            case .webSearch(let searchId):
                flushFetches()
                if let instance = message.webSearches?.first(where: { $0.id == searchId }) {
                    noteWorkStart(index)
                    searchBuffer.append(instance)
                }
            case .urlFetch(let fetchId):
                flushSearches()
                if let fetch = message.urlFetches.first(where: { $0.id == fetchId }) {
                    noteWorkStart(index)
                    fetchBuffer.append(fetch)
                }
            case .toolCall(let toolCallId):
                flushWork()
                if let toolCall = message.toolCalls.first(where: { $0.id == toolCallId }) {
                    runs.append(IdentifiedInlineSegmentRun(
                        id: "toolcall:\(index):\(toolCall.id)",
                        run: .toolCall(toolCall)
                    ))
                }
            }
        }
        flushWork()
        return runs
    }

    /// Whether the indicator below a streaming reply shows: under its text, a
    /// widget or a step that has settled. A reply nothing has arrived of
    /// shows its waiting dots instead, and one whose latest row is a step
    /// still working shows that in the step's header.
    static func showsIndicatorBelowReply(_ message: Message, isRenderingStream: Bool) -> Bool {
        guard message.role == .assistant, isRenderingStream else { return false }
        let segments = message.segments ?? []
        guard !message.content.isEmpty || message.thoughts != nil || message.isThinking || !segments.isEmpty else {
            return false
        }
        if !segments.isEmpty {
            switch inlineSegmentRuns(from: segments, message: message).last?.run {
            case .work:
                // A run that is the latest row stays live until text follows it.
                return false
            case .step(let step):
                return !step.isInFlight
            case .text, .toolCall, nil:
                return true
            }
        }
        // A reply without segments shows its steps above its text.
        if message.content.hasPrefix("<think>") { return message.content.contains("</think>") }
        guard message.content.isEmpty else { return true }
        let isSearching = message.webSearchState?.status == .searching
        let isFetching = message.urlFetches.contains { $0.status == .fetching }
        return !(message.isThinking || isSearching || isFetching)
    }

    /// Renders ordered message segments (text and inline event refs) in the
    /// order they streamed. Each text segment is rendered via the same
    /// markdown pipeline as the non-segmented path; event segments resolve
    /// through the message's `webSearches` / `urlFetches` maps. Adjacent
    /// same-kind event segments are grouped into one row.
    @ViewBuilder
    private func inlineSegmentsView(segments: [MessageSegment]) -> some View {
        let runs = Self.inlineSegmentRuns(from: segments, message: message)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(runs) { identifiedRun in
                switch identifiedRun.run {
                case .text(let text, let isTrailing):
                    let isStreamingText = isTrailing && isRenderingStream
                    LaTeXMarkdownView(
                        content: text,
                        isDarkMode: isDarkMode,
                        isStreaming: isStreamingText,
                        textSelectionEnabled: inlineAssistantTextSelectionEnabled,
                        citationUrls: citationUrls
                    )
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                case .step(let step):
                    workStepBox(step, rowId: identifiedRun.id, isActive: isRenderingStream && step.isInFlight)
                case .toolCall(let toolCall):
                    genUIToolCallView(toolCall)
                case .work(let run):
                    WorkBox(
                        run: run,
                        rowId: identifiedRun.id,
                        isActive: isRenderingStream && identifiedRun.id == runs.last?.id,
                        isStreaming: isRenderingStream,
                        isDarkMode: isDarkMode,
                        thinkingSummary: isRenderingStream ? viewModel.thinkingSummary : nil,
                        webSearchSummary: isRenderingStream ? viewModel.webSearchSummary : nil,
                        expansion: stepExpansion
                    )
                }
            }
        }
    }

    /// A thought, searches or link reads standing alone. Only a step still
    /// running shows the chat service's live summary of it.
    private func workStepBox(_ step: WorkStep, rowId: String, isActive: Bool) -> some View {
        WorkStepBox(
            step: step,
            rowId: rowId,
            isActive: isActive,
            isDarkMode: isDarkMode,
            thinkingSummary: isActive ? viewModel.thinkingSummary : nil,
            webSearchSummary: isActive ? viewModel.webSearchSummary : nil,
            expansion: stepExpansion
        )
    }

    /// The link reads and search of a reply saved before replies kept their
    /// steps in order.
    @ViewBuilder
    private var legacyFetchAndSearchBoxes: some View {
        if !message.urlFetches.isEmpty {
            let step = WorkStep.urlFetches(message.urlFetches)
            workStepBox(step, rowId: Self.legacyFetchesRowId, isActive: isRenderingStream && step.isInFlight)
        }
        if let webSearchState = message.webSearchState {
            let step = legacySearchStep(webSearchState)
            workStepBox(step, rowId: Self.legacySearchRowId, isActive: isRenderingStream && step.isInFlight)
        }
    }

    private func legacySearchStep(_ state: WebSearchState) -> WorkStep {
        .webSearches([WebSearchInstance(
            id: Self.legacySearchId,
            query: state.query,
            status: state.status,
            sources: state.sources,
            reason: state.reason
        )])
    }

    private static let legacySearchId = "search"
    private static let legacyThinkingRowId = "legacy:thinking"
    private static let legacySearchRowId = "legacy:search"
    private static let legacyFetchesRowId = "legacy:fetches"

    private func genUIToolCallView(_ toolCall: GenUIToolCall) -> some View {
        GenUIToolCallView(
            toolCall: toolCall,
            isStreaming: GenUIToolCallPresentation.showsPlaceholder(
                arguments: toolCall.arguments,
                isRenderingStream: isRenderingStream
            ),
            isDarkMode: isDarkMode,
            retryState: viewModel.genUIRetryState(toolCallId: toolCall.id),
            onRetry: (isRenderingStream || !viewModel.canGenerateInCurrentChat) ? nil : {
                viewModel.retryGenUIToolCall(toolCallId: toolCall.id)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentsCoverEntireAssistantMessage(_ segments: [MessageSegment]) -> Bool {
        if message.thoughts != nil || message.isThinking {
            let hasThinkingSegment = segments.contains { segment in
                if case .thinking = segment { return true }
                return false
            }
            if !hasThinkingSegment { return false }
        }
        if !message.content.isEmpty {
            let hasTextSegment = segments.contains { segment in
                if case .text(let text) = segment, !text.isEmpty { return true }
                return false
            }
            if !hasTextSegment { return false }
        }
        for toolCall in message.toolCalls {
            let hasToolCallSegment = segments.contains { segment in
                if case .toolCall(let id) = segment, id == toolCall.id { return true }
                return false
            }
            if !hasToolCallSegment { return false }
        }
        return true
    }

    /// URLs the router annotated as web-search citations on this message.
    /// Used by the markdown renderer to rewrite plain markdown citation links
    /// to use the host domain as their display text.
    private var citationUrls: Set<String>? {
        var urls: Set<String> = []
        if let annotations = message.annotations {
            for annotation in annotations where annotation.type == "url_citation" {
                let url = annotation.url_citation.url
                if !url.isEmpty { urls.insert(url) }
            }
        }
        if let sources = message.webSearchState?.sources {
            for source in sources where !source.url.isEmpty {
                urls.insert(source.url)
            }
        }
        return urls.isEmpty ? nil : urls
    }

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: .trailing, spacing: 4) {
            // Show attachment indicators above the message bubble
            if message.role == .user && !message.attachments.isEmpty {
                MessageAttachmentIndicator(
                    attachments: message.attachments,
                    isDarkMode: isDarkMode
                )
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                // Show the loading dots for a fresh streaming assistant response (but not if we have thoughts or are thinking)
                if message.role == .assistant &&
                    message.content.isEmpty &&
                    message.thoughts == nil &&
                    !message.isThinking &&
                    (message.segments?.isEmpty ?? true) &&
                    isRenderingStream {
                    VStack(alignment: .leading, spacing: 4) {
                        legacyFetchAndSearchBoxes

                        // Show loading dots unless a web search is actively in
                        // flight, in which case the search box itself pulses
                        if message.webSearchState?.status != .searching {
                            LoadingDotsView(isDarkMode: isDarkMode)
                                .padding(.horizontal)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Assistant messages whose timeline-derived segments cover
                // the entire message (thinking, web search, content, tool
                // calls) render through the unified inline-segments
                // pipeline so chronological order matches the webapp.
                else if message.role == .assistant,
                        let segments = message.segments,
                        !segments.isEmpty,
                        segmentsCoverEntireAssistantMessage(segments) {
                    inlineSegmentsView(segments: segments)
                }

                // If the message is thinking or has thoughts, display them in a thinking box
                else if message.isThinking || message.thoughts != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        workStepBox(
                            .thinking(
                                content: message.thoughts ?? "",
                                isThinking: message.isThinking,
                                duration: message.generationTimeSeconds,
                                startedAt: nil
                            ),
                            rowId: Self.legacyThinkingRowId,
                            isActive: message.isThinking && isRenderingStream
                        )

                        if let segments = message.segments, !segments.isEmpty {
                            inlineSegmentsView(segments: segments)
                        } else {
                            legacyFetchAndSearchBoxes

                            if !message.content.isEmpty {
                                LaTeXMarkdownView(
                                    content: message.content,
                                    isDarkMode: isDarkMode,
                                    isStreaming: isRenderingStream,
                                    textSelectionEnabled: inlineAssistantTextSelectionEnabled,
                                    citationUrls: citationUrls
                                )
                                    .equatable()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transaction { transaction in
                                        transaction.animation = nil
                                    }
                            }
                        }
                    }
                }
                
                // Legacy support: if content still has <think> tags, parse and display
                else if let parsed = getParsedMessageContent() {
                    VStack(alignment: .leading, spacing: 4) {
                        let isThinking = !message.content.contains("</think>")
                        workStepBox(
                            .thinking(
                                content: parsed.thinkingText,
                                isThinking: isThinking,
                                duration: message.generationTimeSeconds,
                                startedAt: nil
                            ),
                            rowId: Self.legacyThinkingRowId,
                            isActive: isThinking && isRenderingStream
                        )
                        
                        // Remainder: text after </think> if present
                        if !parsed.remainderText.isEmpty {
                            LaTeXMarkdownView(
                                content: parsed.remainderText,
                                isDarkMode: isDarkMode,
                                isStreaming: isRenderingStream,
                                textSelectionEnabled: inlineAssistantTextSelectionEnabled,
                                citationUrls: citationUrls
                            )
                                .equatable()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                        }
                    }
                }
                
                // Very large user messages stay collapsed so transcript rows remain cheap,
                // but retain the same visual treatment as an ordinary user bubble.
                else if message.role == .user && message.shouldDisplayAsAttachment {
                    LongUserMessagePreview(
                        content: message.content,
                        isDarkMode: isDarkMode
                    ) {
                        selectLongMessageOnPresentation = false
                        showLongMessageSheet = true
                    }
                }

                else if !message.content.isEmpty || !message.toolCalls.isEmpty {
                    if message.role == .user {
                        AdaptiveMarkdownText(
                            content: message.content,
                            isDarkMode: isDarkMode,
                            selectionRequestID: userTextSelectionRequest,
                            bubbleContextMenuEnabled: canShowUserMessageMenu
                        )
                    } else if let segments = message.segments, !segments.isEmpty {
                        // Render events inline in the order they streamed.
                        inlineSegmentsView(segments: segments)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            legacyFetchAndSearchBoxes

                            LaTeXMarkdownView(
                                content: message.content,
                                isDarkMode: isDarkMode,
                                isStreaming: isRenderingStream,
                                textSelectionEnabled: inlineAssistantTextSelectionEnabled,
                                citationUrls: citationUrls
                            )
                                .equatable()
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Widgets of a reply with no segments to place
                            // them in.
                            ForEach(message.toolCalls) { toolCall in
                                genUIToolCallView(toolCall)
                            }
                        }
                    }
                }

                if message.hasUnsupportedGenUI {
                    UnsupportedGenUINoticeView(isDarkMode: isDarkMode)
                        .padding(.top, message.content.isEmpty && message.thoughts == nil ? 0 : 8)
                }

                // Persistent streaming indicator at the bottom of the
                // currently rendered assistant content. Only shown once
                // initial content has started arriving so we don't double up
                // with the initial `LoadingDotsView` placeholder above, nor
                // with a working step's header.
                if Self.showsIndicatorBelowReply(message, isRenderingStream: isRenderingStream) {
                    StreamingIndicator(isDarkMode: isDarkMode)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Show an error box if the stream failed, with a button that
                // continues the partial response or generates it again.
                if shouldShowStreamError(message: message), let failure = viewModel.shownFailure {
                    let presentation = StreamErrorPresentation(failure.error, occurredAt: failure.at)
                    ErrorMessageView(
                        presentation: presentation,
                        details: failure.error.message,
                        occurredAt: failure.at,
                        isDarkMode: isDarkMode,
                        onUpgrade: { viewModel.showRateLimitPaywall = true },
                        onUnlock: { Task { await viewModel.reattemptPasskeyRecovery() } },
                        retry: streamErrorRetryButton(resends: presentation.resends)
                    )
                    .padding(.top, message.content.isEmpty && message.thoughts == nil ? 0 : 8)
                }
                
                // Add action buttons for assistant messages (only when not streaming)
                if showsAssistantActionSection {
                    VStack(alignment: .leading) {
                        MessageSecurityMetadataView(
                            modelDisplayName: message.modelDisplayName,
                            isDarkMode: isDarkMode
                        )

                        if !viewModel.isCurrentChatSafeguardFlagged {
                            HStack(spacing: 16) {
                                if message.hasVisibleAssistantContent {
                                    Button {
                                        showRawContentModal = true
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 16))
                                            .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5))
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .accessibilityLabel("Copy")
                                    .accessibleHitTarget()

                                    if viewModel.canUseReadAloud,
                                       SpeechTextProcessor.canRead(message),
                                       let chatId = viewModel.currentChat?.id {
                                        ReadAloudButton(
                                            player: viewModel.speechPlayer,
                                            owner: SpeechOwner(chatId: chatId, messageId: message.id),
                                            isDarkMode: isDarkMode
                                        ) {
                                            try viewModel.toggleReadAloud(messageId: message.id)
                                        }
                                    }
                                }

                                // Regenerate button - only on the last eligible assistant message,
                                // unless the error box already offers the same action
                                if canRegenerateAssistantResponse && streamErrorRetry != .regenerate {
                                    Button {
                                        viewModel.regenerateLastResponse()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 16))
                                            .foregroundColor(isDarkMode ? .white.opacity(0.5) : .black.opacity(0.5))
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .accessibilityLabel("Regenerate response")
                                    .accessibleHitTarget()
                                }

                                if message.hasVisibleAssistantContent && showsAssistantMoreMenu {
                                    assistantMoreMenu
                                }

                                Spacer()
                            }
                        }

                        // Sources button - only show if we have web search sources
                        if let webSearchState = message.webSearchState,
                           !webSearchState.sources.isEmpty {
                            SourcesButton(
                                sources: webSearchState.sources,
                                isDarkMode: isDarkMode
                            ) {
                                showSourcesSheet = true
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    // AI disclaimer - only after a visible final assistant response
                    if isLastMessage && message.hasVisibleAssistantContent {
                        Text("AI can make mistakes. Verify important information.")
                            .font(.caption2)
                            .foregroundColor(isDarkMode ? .white.opacity(0.35) : .black.opacity(0.35))
                    }
                }

                }
                .padding(.vertical, message.role == .user && message.content.isEmpty ? 0 : 8)
                .padding(.horizontal, message.role == .user && !message.content.isEmpty ? 12 : 0)
                .background {
                    if message.role == .user && !message.content.isEmpty {
                        if #available(iOS 26, *) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.thickMaterial)
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.userMessageBackground(isDarkMode: isDarkMode))
                        }
                    }
                }
                .if(
                        message.role == .user
                            && !message.content.isEmpty
                        && canShowUserMessageMenu
                ) { view in
                    view.contextMenu {
                        Button {
                            if message.shouldDisplayAsAttachment {
                                selectLongMessageOnPresentation = true
                                showLongMessageSheet = true
                            } else {
                                userTextSelectionRequest &+= 1
                            }
                        } label: {
                            Label("Select Text", systemImage: "selection.pin.in.out")
                        }

                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        if canUseUserMessageActions {
                            Button {
                                viewModel.beginMessageEdit(at: messageIndex)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }

                        if viewModel.canForkMessage(at: messageIndex) {
                            Button(action: forkFromHere) {
                                Label(
                                    "Fork",
                                    systemImage: Constants.ChatFork.actionSystemImage
                                )
                            }
                        }
                    }
                }
                .modifier(MessageBubbleModifier(isUserMessage: message.role == .user))

            }
        }
        .padding(.horizontal, 4)
        // Announce who is speaking while keeping inner controls (links, tool
        // calls, action buttons, text selection) individually accessible.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "You said" : "Assistant said")
        .sheet(isPresented: $showLongMessageSheet, onDismiss: {
            selectLongMessageOnPresentation = false
        }) {
            LongMessageDetailView(
                message: message,
                activateSelection: selectLongMessageOnPresentation
            )
            .presentationDetents([.medium, .large])
            .iPadSheetSizing()
        }
        .sheet(isPresented: $showRawContentModal) {
            RawContentModalView(message: message)
                .presentationDetents([.medium, .large])
                .iPadSheetSizing()
                .presentationBackground(Color.sheetBackground(isDarkMode: isDarkMode))
        }
        .sheet(isPresented: $showSourcesSheet) {
            if let sources = message.webSearchState?.sources {
                SourcesSheetView(sources: sources, isDarkMode: isDarkMode)
                    .presentationDetents([.medium, .large])
                    .iPadSheetSizing()
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let currentChat = viewModel.currentChat {
                ShareChatView(
                    chatTitle: currentChat.title,
                    chatId: currentChat.id
                )
                .id(currentChat.id)
                .presentationDetents([.medium, .large])
                .iPadSheetSizing()
            }
        }
        .onChange(of: isAnyMessageSheetPresented) { _, value in
            viewModel.showMessageSheet = value
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "cite" {
                let path = url.absoluteString.dropFirst(5)
                if let tildeIndex = path.firstIndex(of: "~") {
                    let afterFirstTilde = path[path.index(after: tildeIndex)...]
                    if let secondTildeIndex = afterFirstTilde.firstIndex(of: "~") {
                        let encodedUrl = String(afterFirstTilde[..<secondTildeIndex])
                        if let decodedUrl = encodedUrl.removingPercentEncoding {
                            LinkOpener.open(decodedUrl)
                            return .handled
                        }
                    }
                }
                return .handled
            }
            return LinkOpener.canOpen(url) ? .systemAction : .discarded
        })
    }

    private var responseContent: String {
        if message.thoughts != nil {
            return message.content.hasPrefix("<think>") ? "" : message.content
        }
        if message.content.hasPrefix("<think>") {
            let tagSuffix = "</think>"
            if let endTagRange = message.content.range(of: tagSuffix) {
                return String(message.content[endTagRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return message.content
    }

    /// Parse message content with <think> tags
    private func getParsedMessageContent() -> (thinkingText: String, remainderText: String)? {
        // Parse if content starts with <think>
        guard message.content.hasPrefix("<think>") else { return nil }
        
        let tagPrefix = "<think>"
        let tagSuffix = "</think>"
        let start = message.content.index(message.content.startIndex, offsetBy: tagPrefix.count)
        
        if let endTagRange = message.content.range(of: tagSuffix, range: start..<message.content.endIndex) {
            let thinkingText = String(message.content[start..<endTagRange.lowerBound])
            let remainderText = String(message.content[endTagRange.upperBound...])
            return (thinkingText, remainderText)
        } else {
            // If the closing tag hasn't been received, treat all text after <think> as the thinking text.
            let thinkingText = String(message.content[start...])
            return (thinkingText, "")
        }
    }
}

enum UserMessagePresentation {
    static let previewCharacterLimit = 360

    static func preview(for content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previewCharacterLimit else { return trimmed }
        return String(trimmed.prefix(previewCharacterLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// A deterministic initial selection is used because SwiftUI's context
    /// menu does not expose the long-press location to its action closure.
    static func firstSelectableRange(in text: String) -> NSRange? {
        let value = text as NSString
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        let start = value.rangeOfCharacter(from: nonWhitespace)
        guard start.location != NSNotFound else { return nil }
        let remainder = NSRange(location: start.location, length: value.length - start.location)
        let whitespace = value.rangeOfCharacter(from: .whitespacesAndNewlines, range: remainder)
        let end = whitespace.location == NSNotFound ? value.length : whitespace.location
        return NSRange(location: start.location, length: max(1, end - start.location))
    }
}

private func userMessageAttributedText(content: String, isDarkMode: Bool) -> NSAttributedString {
    var parsed = (try? AttributedString(
        markdown: content,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(content)
    let runs = parsed.runs.map { ($0.range, $0.inlinePresentationIntent) }
    let bodyFont = UIFont.preferredFont(forTextStyle: .body)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 2

    parsed.uiKit.font = bodyFont
    parsed.uiKit.foregroundColor = UIColor(Color.userMessageForeground(isDarkMode: isDarkMode))
    parsed.uiKit.paragraphStyle = paragraphStyle

    for (range, intent) in runs {
        guard let intent else { continue }
        if intent.contains(.code) {
            parsed[range].uiKit.font = UIFont.monospacedSystemFont(
                ofSize: bodyFont.pointSize,
                weight: intent.contains(.stronglyEmphasized) ? .bold : .regular
            )
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty,
               let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(traits) {
                parsed[range].uiKit.font = UIFont(descriptor: descriptor, size: bodyFont.pointSize)
            }
        }
        if intent.contains(.strikethrough) {
            parsed[range].uiKit.strikethroughStyle = .single
        }
    }
    return NSAttributedString(parsed)
}

private struct LongUserMessagePreview: View {
    let content: String
    let isDarkMode: Bool
    let openAction: () -> Void

    private var attributedPreview: AttributedString {
        AttributedString(userMessageAttributedText(
            content: UserMessagePresentation.preview(for: content),
            isDarkMode: isDarkMode
        ))
    }

    var body: some View {
        Button(action: openAction) {
            VStack(alignment: .leading, spacing: 6) {
                Text(attributedPreview)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.78),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    }

                Text("Show more")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.userMessageForeground(isDarkMode: isDarkMode).opacity(0.65))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message preview. \(UserMessagePresentation.preview(for: content))")
        .accessibilityHint("Shows the full message")
    }
}

private struct LongMessageDetailView: View {
    let message: Message
    let activateSelection: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Color.chatBackground(isDarkMode: colorScheme == .dark)
                .frame(height: 20)

            AttributedSelectableUserTextView(
                content: message.content,
                isDarkMode: colorScheme == .dark,
                activateSelection: activateSelection
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .background(Color.chatBackground(isDarkMode: colorScheme == .dark))
        }
    }
}

private struct AttributedSelectableUserTextView: UIViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let activateSelection: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if context.coordinator.needsTextUpdate(content: content, isDarkMode: isDarkMode) {
            textView.attributedText = userMessageAttributedText(
                content: content,
                isDarkMode: isDarkMode
            )
            textView.linkTextAttributes = [
                .foregroundColor: UIColor(Color.userMessageForeground(isDarkMode: isDarkMode)),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        }
        guard activateSelection, !context.coordinator.didActivateSelection else { return }
        context.coordinator.didActivateSelection = true
        // Sheet presentation and context-menu dismissal complete on separate
        // UIKit transactions. Wait briefly so first-responder activation is
        // not discarded while the sheet is still entering the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            textView.activateInitialTextSelection()
        }
    }

    final class Coordinator {
        var didActivateSelection = false
        private var lastContent: String?
        private var lastIsDarkMode: Bool?

        func needsTextUpdate(content: String, isDarkMode: Bool) -> Bool {
            guard lastContent != content || lastIsDarkMode != isDarkMode else { return false }
            lastContent = content
            lastIsDarkMode = isDarkMode
            return true
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.textColor = colorScheme == .dark ? UIColor(white: 1.0, alpha: 0.92) : UIColor(white: 0.0, alpha: 0.92)
    }
}

private struct RawContentModalView: View {
    let message: Message

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCopyAllFeedback = false
    @State private var showCopyResponseFeedback = false
    @State private var showCopyThoughtsFeedback = false

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var hasThoughts: Bool {
        if let thoughts = message.thoughts, !thoughts.isEmpty {
            return true
        }
        return message.content.hasPrefix("<think>")
    }

    private var thoughtsContent: String? {
        if let thoughts = message.thoughts, !thoughts.isEmpty {
            return thoughts
        }
        if message.content.hasPrefix("<think>") {
            let tagPrefix = "<think>"
            let tagSuffix = "</think>"
            let start = message.content.index(message.content.startIndex, offsetBy: tagPrefix.count)

            if let endTagRange = message.content.range(of: tagSuffix, range: start..<message.content.endIndex) {
                return String(message.content[start..<endTagRange.lowerBound])
            } else {
                return String(message.content[start...])
            }
        }
        return nil
    }

    private var responseContent: String {
        if message.thoughts != nil {
        return message.content.hasPrefix("<think>") ? "" : message.content
        }
        if message.content.hasPrefix("<think>") {
            let tagSuffix = "</think>"
            if let endTagRange = message.content.range(of: tagSuffix) {
                return String(message.content[endTagRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return message.content
    }

    private var fullRawContent: String {
        if let thoughts = thoughtsContent, !thoughts.isEmpty {
            if !responseContent.isEmpty {
                return thoughts + "\n\n" + responseContent
            }
            return thoughts
        }
        return responseContent
    }

    private var sheetBackground: Color {
        Color.sheetBackground(isDarkMode: isDarkMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SelectableTextView(text: fullRawContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)

                Divider()

                VStack(spacing: 10) {
                    copyButton(
                        action: copyAll,
                        icon: showCopyAllFeedback ? "checkmark" : "doc.on.doc",
                        label: showCopyAllFeedback ? "Copied All!" : "Copy All"
                    )

                    if hasThoughts && !responseContent.isEmpty {
                        copyButton(
                            action: copyResponse,
                            icon: showCopyResponseFeedback ? "checkmark" : "text.quote",
                            label: showCopyResponseFeedback ? "Copied Response!" : "Copy Response"
                        )
                    }

                    if hasThoughts {
                        copyButton(
                            action: copyThoughts,
                            icon: showCopyThoughtsFeedback ? "checkmark" : "brain",
                            label: showCopyThoughtsFeedback ? "Copied Thoughts!" : "Copy Thoughts"
                        )
                    }
                }
                .padding(20)
            }
            .background(sheetBackground)
            .navigationTitle("Raw Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
        }
    }

    private func copyButton(action: @escaping () -> Void, icon: String, label: String) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(isDarkMode ? .white : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func copyAll() {
        UIPasteboard.general.string = fullRawContent
        withAnimation {
            showCopyAllFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopyAllFeedback = false
            }
        }
    }

    private func copyResponse() {
        UIPasteboard.general.string = responseContent
        withAnimation {
            showCopyResponseFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopyResponseFeedback = false
            }
        }
    }

    private func copyThoughts() {
        if let thoughts = thoughtsContent {
            UIPasteboard.general.string = thoughts
            withAnimation {
                showCopyThoughtsFeedback = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    showCopyThoughtsFeedback = false
                }
            }
        }
    }
}

/// Modifier that handles message bubble sizing based on sender
struct MessageBubbleModifier: ViewModifier {
    let isUserMessage: Bool
    
    func body(content: Content) -> some View {
        Group {
            if isUserMessage {
                content
                    // User messages get adaptive width based on content with minimum width
                    .frame(minWidth: 60, idealWidth: nil, maxWidth: max(60, UIScreen.main.bounds.width * 0.85), alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                content
                    // Assistant messages get nearly full width
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A specialized markdown text view for user messages
struct AdaptiveMarkdownText: View {
    let content: String
    let isDarkMode: Bool
    let horizontalPadding: CGFloat
    let selectionRequestID: Int
    let bubbleContextMenuEnabled: Bool

    init(
        content: String,
        isDarkMode: Bool,
        horizontalPadding: CGFloat = 0,
        selectionRequestID: Int = 0,
        bubbleContextMenuEnabled: Bool = true
    ) {
        self.content = content
        self.isDarkMode = isDarkMode
        self.horizontalPadding = horizontalPadding
        self.selectionRequestID = selectionRequestID
        self.bubbleContextMenuEnabled = bubbleContextMenuEnabled
    }

    var body: some View {
        InlineSelectableUserText(
            content: content,
            isDarkMode: isDarkMode,
            selectionRequestID: selectionRequestID,
            bubbleContextMenuEnabled: bubbleContextMenuEnabled
        )
            .padding(.horizontal, horizontalPadding)
    }
}

/// Textual and SwiftUI selection surfaces cannot drag handles reliably inside
/// UIHostingConfiguration table cells. A non-scrolling UITextView keeps the
/// system selection interaction inline without changing the bubble layout.
private struct InlineSelectableUserText: UIViewRepresentable {
    let content: String
    let isDarkMode: Bool
    let selectionRequestID: Int
    let bubbleContextMenuEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selectionRequestID: selectionRequestID)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = InlineSelectableUITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.heightTracksTextView = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.delegate = context.coordinator
        textView.bubbleContextMenuEnabled = bubbleContextMenuEnabled
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let shouldActivateSelection = context.coordinator.update(
            selectionRequestID: selectionRequestID
        )
        (textView as? InlineSelectableUITextView)?.bubbleContextMenuEnabled = bubbleContextMenuEnabled
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(Color.userMessageForeground(isDarkMode: isDarkMode)),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let attributedText = makeAttributedText()
        if !textView.attributedText.isEqual(to: attributedText) {
            textView.attributedText = attributedText
            textView.invalidateIntrinsicContentSize()
        }
        if shouldActivateSelection {
            // Let SwiftUI dismiss its context menu before making the native
            // text input first responder and revealing selection handles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak textView] in
                textView?.activateInitialTextSelection()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: UITextView,
        context: Context
    ) -> CGSize? {
        let maximumWidth = proposal.width ?? UIScreen.main.bounds.width * 0.85
        textView.textContainer.size = CGSize(width: maximumWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.ensureLayout(for: textView.textContainer)

        let initialRect = textView.layoutManager.usedRect(for: textView.textContainer)
        let measuredWidth = min(maximumWidth, ceil(initialRect.width))
        textView.textContainer.size = CGSize(width: measuredWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let finalRect = textView.layoutManager.usedRect(for: textView.textContainer)

        return CGSize(
            width: measuredWidth,
            height: ceil(max(finalRect.height, UIFont.preferredFont(forTextStyle: .body).lineHeight))
        )
    }

    private func makeAttributedText() -> NSAttributedString {
        userMessageAttributedText(content: content, isDarkMode: isDarkMode)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var selectionRequestID: Int

        init(selectionRequestID: Int) {
            self.selectionRequestID = selectionRequestID
        }

        func update(selectionRequestID: Int) -> Bool {
            guard self.selectionRequestID != selectionRequestID else { return false }
            self.selectionRequestID = selectionRequestID
            return true
        }
    }
}

private extension UITextView {
    func activateInitialTextSelection() {
        guard let range = UserMessagePresentation.firstSelectableRange(in: text) else { return }
        selectedRange = range
        becomeFirstResponder()
    }
}

private final class InlineSelectableUITextView: UITextView {
    var bubbleContextMenuEnabled = true

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if bubbleContextMenuEnabled,
           gestureRecognizer is UILongPressGestureRecognizer,
           gestureRecognizer.view === self,
           selectedRange.length == 0 {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

struct ThinkingChunkView: View, Equatable {
    let chunk: ThinkingChunk
    let isDarkMode: Bool

    static func == (lhs: ThinkingChunkView, rhs: ThinkingChunkView) -> Bool {
        if lhs.chunk.isComplete && rhs.chunk.isComplete {
            return lhs.chunk.id == rhs.chunk.id && lhs.isDarkMode == rhs.isDarkMode
        }
        return lhs.chunk.id == rhs.chunk.id &&
               lhs.chunk.content == rhs.chunk.content &&
               lhs.isDarkMode == rhs.isDarkMode
    }

    var body: some View {
        Text(chunk.content)
            .font(.system(.body))
            .foregroundColor(isDarkMode ? .white.opacity(0.9) : Color.black.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Constants.UI.WorkSteps.thoughtParagraphSpacing)
    }
}

struct LoadingDotsView: View {    
    let isDarkMode: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .modifier(PulsingAnimation(delay: 0.2 * Double(index)))
            }
        }
        .foregroundColor(isDarkMode ? .white : .black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating response")
    }
}

struct InlineLoadingDotsView: View {
    let isDarkMode: Bool
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 4, height: 4)
                    .modifier(PulsingAnimation(delay: 0.2 * Double(index)))
            }
        }
        .foregroundColor(isDarkMode ? .white.opacity(0.8) : Color.black.opacity(0.7))
        .accessibilityHidden(true)
    }
}

struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct PulsingAnimation: ViewModifier {
    let delay: Double
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .scaleEffect(isPulsing ? 1.0 : 0.6)
                .opacity(isPulsing ? 1.0 : 0.3)
                .animation(
                    Animation.easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(delay),
                    value: isPulsing
                )
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isPulsing = true
                    }
                }
        }
    }
}

/// Shimmer effect for in-progress text: the content renders dimmed while a
/// bright band of the content itself sweeps across, so the effect stays
/// visible for any text color in both light and dark mode.
struct TextShimmerAnimation: ViewModifier {
    @State private var offset: CGFloat = -1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(0.5)
                .overlay(
                    content.mask(
                        GeometryReader { geometry in
                            let shimmerWidth = geometry.size.width * 0.5
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white,
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: shimmerWidth)
                            .offset(x: offset * (geometry.size.width + shimmerWidth))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    )
                )
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: false)
                    ) {
                        offset = 1.0
                    }
                }
        }
    }
}

struct UnsupportedGenUINoticeView: View {
    let isDarkMode: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Component unavailable")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isDarkMode ? .white : .black)

                Text("This message includes a component that isn't available in this version of the app.")
                    .font(.caption)
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct ErrorMessageView: View {
    struct Retry {
        let label: String
        let systemImage: String
        let action: () -> Void
    }

    let presentation: StreamErrorPresentation
    /// The chat service's own description of the error.
    let details: String
    /// When the error happened, from which a wait it asks for counts.
    let occurredAt: Date?
    let isDarkMode: Bool
    var onUpgrade: (() -> Void)? = nil
    var onUnlock: (() -> Void)? = nil
    var retry: Retry? = nil

    @State private var shownAt = Date()
    @State private var showsDetails = false

    private var accentColor: Color {
        switch presentation.kind {
        case .rateLimit, .busy, .queueFull: return .orange
        default: return .red
        }
    }

    private var headerIcon: String {
        switch presentation.kind {
        case .rateLimit: return "gauge.with.dots.needle.67percent"
        case .connection: return "wifi.exclamationmark"
        case .verification: return "exclamationmark.shield"
        case .key: return "key.slash"
        default: return "exclamationmark.triangle"
        }
    }

    private var retryAt: Date? {
        presentation.retryAfter.map { (occurredAt ?? shownAt).addingTimeInterval(TimeInterval($0)) }
    }

    private var secondaryTextColor: Color {
        isDarkMode ? .white.opacity(0.7) : .black.opacity(0.7)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundColor(accentColor)
                    .font(.system(size: 16))

                Text(presentation.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isDarkMode ? .white : .black)

                Spacer()

                if !details.isEmpty {
                    Button {
                        withAnimation { showsDetails.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .rotationEffect(.degrees(showsDetails ? 180 : 0))
                            .foregroundColor(secondaryTextColor)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(showsDetails ? "Hide error details" : "Show error details")
                }
            }
            .accessibilityElement(children: .contain)

            Text(presentation.suggestion)
                .font(.subheadline)
                .foregroundColor(secondaryTextColor)
                .multilineTextAlignment(.leading)

            if showsDetails {
                Text(details)
                    .font(.caption.monospaced())
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            if let onUpgrade, presentation.offersUpgrade {
                Button(action: onUpgrade) {
                    Text("Upgrade to Premium")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentPrimary)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            if let onUnlock, presentation.offersUnlock {
                outlinedButton(label: "Unlock", systemImage: "key", action: onUnlock)
            }

            if let retry, presentation.offersRetry {
                if let retryAt, retryAt > Date() {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = Int(ceil(retryAt.timeIntervalSince(context.date)))
                        outlinedButton(
                            label: seconds > 0 ? "\(retry.label) in \(seconds)s" : retry.label,
                            systemImage: retry.systemImage,
                            action: retry.action
                        )
                        .disabled(seconds > 0)
                        .opacity(seconds > 0 ? 0.5 : 1)
                    }
                } else {
                    outlinedButton(label: retry.label, systemImage: retry.systemImage, action: retry.action)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private func outlinedButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundColor(isDarkMode ? .white : .black)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentColor.opacity(0.5), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Sources Button and Sheet

/// Button showing "Sources" with overlapping favicons
private struct SourcesButton: View {
    let sources: [WebSearchSource]
    let isDarkMode: Bool
    let action: () -> Void

    private static let label = "Sources"

    private var labelWidth: CGFloat {
        let descriptor = UIFontDescriptor
            .preferredFontDescriptor(withTextStyle: .footnote)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]])
        let font = UIFont(descriptor: descriptor, size: 0)
        return (Self.label as NSString).size(withAttributes: [.font: font]).width
    }

    /// How many overlapping favicons fit beside the label without the pill
    /// exceeding its share of the screen. Each favicon after the first only
    /// adds its non-overlapped portion.
    private var maxFaviconCount: Int {
        let layout = Constants.SourcesButton.self
        let maxWidth = UIScreen.main.bounds.width * layout.maxWidthFraction
        let fixedWidth = layout.horizontalPadding * 2 + labelWidth + layout.labelSpacing
        let faviconStride = layout.faviconSize - layout.faviconOverlap
        let available = maxWidth - fixedWidth - layout.faviconOverlap
        return max(1, Int(available / faviconStride))
    }

    private var uniqueDomainSources: [(domain: String, url: String)] {
        var seen = Set<String>()
        var entries: [(domain: String, url: String)] = []
        let limit = maxFaviconCount
        for source in sources {
            let domain = getDomain(from: source.url)
            if !seen.contains(domain) {
                seen.insert(domain)
                entries.append((domain: domain, url: source.url))
            }
            if entries.count >= limit { break }
        }
        return entries
    }

    private func getDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func sourceFavicon(url: String, zIndex: Double) -> some View {
        let backgroundColor: Color = isDarkMode ? .black : .white
        let borderColor: Color = isDarkMode
            ? .white.opacity(0.2)
            : .black.opacity(0.1)

        return FaviconImage(
            url: url,
            placeholderColor: .gray,
            placeholderFontSize: 10
        )
        .frame(width: Constants.SourcesButton.faviconSize, height: Constants.SourcesButton.faviconSize)
        .background(backgroundColor)
        .clipShape(Circle())
        .overlay(Circle().stroke(borderColor, lineWidth: 1))
        .zIndex(zIndex)
    }

    var body: some View {
        let displayedSources = uniqueDomainSources

        Button(action: action) {
            HStack(spacing: Constants.SourcesButton.labelSpacing) {
                Text(Self.label)
                    .font(.system(.footnote, weight: .medium))

                // Overlapping favicons
                HStack(spacing: -Constants.SourcesButton.faviconOverlap) {
                    ForEach(Array(displayedSources.enumerated()), id: \.offset) { index, entry in
                        sourceFavicon(
                            url: entry.url,
                            zIndex: Double(displayedSources.count - index)
                        )
                    }
                }
            }
            .padding(.horizontal, Constants.SourcesButton.horizontalPadding)
            .padding(.vertical, 8)
            .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            .cornerRadius(20)
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(isDarkMode ? .white : .black)
        .accessibilityLabel(Self.label)
        .accessibilityValue("\(sources.count) source\(sources.count == 1 ? "" : "s")")
        .accessibilityHint("Shows web sources")
    }
}

/// Sheet view showing all sources
private struct SourcesSheetView: View {
    let sources: [WebSearchSource]
    let isDarkMode: Bool

    private func getDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sources) { source in
                        Button {
                            LinkOpener.open(source.url)
                        } label: {
                            HStack(spacing: 12) {
                                FaviconImage(
                                    url: source.url,
                                    placeholderColor: .secondary,
                                    placeholderFontSize: 12
                                )
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(.system(.subheadline, weight: .medium))
                                        .foregroundColor(isDarkMode ? .white : .black)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Text(getDomain(from: source.url))
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background((isDarkMode ? Color.black : Color(UIColor.systemBackground)).ignoresSafeArea())
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(isDarkMode ? Color.black : Color(UIColor.systemBackground), for: .navigationBar)
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}
