//
//  MessageView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import MarkdownUI
import SwiftMath
import UIKit

/// Preference key for tracking which thinking box is expanded
struct ThinkingBoxExpansionPreferenceKey: PreferenceKey {
    static var defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct MessageView: View {
    let message: Message
    let isDarkMode: Bool
    let isLastMessage: Bool
    let isLoading: Bool
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel
    @State private var showCopyFeedback = false
    @State private var cachedParsedContent: (thinkingText: String, remainderText: String, contentHash: Int)? = nil
    @State private var showLongMessageSheet = false
    @State private var showRawContentModal = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                // Show the loading dots for a fresh streaming assistant response (but not if we have thoughts or are thinking)
                if message.role == .assistant &&
                    message.content.isEmpty &&
                    message.thoughts == nil &&
                    !message.isThinking &&
                    isLoading &&
                    isLastMessage {
                    LoadingDotsView(isDarkMode: isDarkMode)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // If the message is thinking or has thoughts, display them in a thinking box
                else if message.isThinking || message.thoughts != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        CollapsibleThinkingBox(
                            messageId: message.id,
                            thinkingText: message.thoughts ?? "",
                            isDarkMode: isDarkMode,
                            isCollapsible: !message.isThinking,
                            isStreaming: message.isThinking && isLoading && isLastMessage,
                            generationTimeSeconds: message.generationTimeSeconds,
                            messageCollapsed: message.isCollapsed
                        )
                        
                                if !message.content.isEmpty {
                            if !message.contentChunks.isEmpty {
                                ChunkedContentView(chunks: message.contentChunks, isDarkMode: isDarkMode, isStreaming: isLoading && isLastMessage)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                LaTeXMarkdownView(content: message.content, isDarkMode: isDarkMode, isStreaming: isLoading && isLastMessage)
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
                        CollapsibleThinkingBox(
                            messageId: message.id,
                            thinkingText: parsed.thinkingText,
                            isDarkMode: isDarkMode,
                            isCollapsible: message.content.contains("</think>"),
                            isStreaming: isLoading && isLastMessage,
                            generationTimeSeconds: message.generationTimeSeconds,
                            messageCollapsed: message.isCollapsed
                        )
                        
                        // Remainder: text after </think> if present
                        if !parsed.remainderText.isEmpty {
                            LaTeXMarkdownView(content: parsed.remainderText, isDarkMode: isDarkMode, isStreaming: isLoading && isLastMessage)
                                .equatable()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                        }
                    }
                }
                
                // Display long user messages as an attachment-style preview that expands on tap
                else if message.role == .user && message.shouldDisplayAsAttachment {
                    LongMessageAttachmentView(message: message, isDarkMode: isDarkMode) {
                        showLongMessageSheet = true
                    }
                }

                else if !message.content.isEmpty {
                    if message.streamError != nil {
                        ErrorMessageView(errorMessage: message.streamError!, isDarkMode: isDarkMode)
                    } else if message.role == .user {
                        AdaptiveMarkdownText(content: message.content, isDarkMode: isDarkMode)
                    } else if !message.contentChunks.isEmpty {
                        ChunkedContentView(chunks: message.contentChunks, isDarkMode: isDarkMode, isStreaming: isLoading && isLastMessage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LaTeXMarkdownView(content: message.content, isDarkMode: isDarkMode, isStreaming: isLoading && isLastMessage)
                            .equatable()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // Add copy button for assistant messages (only when not streaming)
                if message.role == .assistant &&
                   (!message.content.isEmpty || message.thoughts != nil) &&
                   !(isLoading && isLastMessage) {
                    HStack {
                        Button {
                            Task { @MainActor in
                                showRawContentModal = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12))
                                Text("Copy")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(isDarkMode ? .white.opacity(0.6) : .black.opacity(0.6))
                        }
                        .buttonStyle(PlainButtonStyle())

                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, message.role == .user ? 12 : 0)
            .background {
                if message.role == .user {
                    if #available(iOS 26, *) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.thickMaterial)
                    } else {
                        Color.userMessageBackground(isDarkMode: isDarkMode)
                    }
                }
            }
            .cornerRadius(16)
            .modifier(MessageBubbleModifier(isUserMessage: message.role == .user))
            .onLongPressGesture {
                if (message.role == .assistant && (!message.content.isEmpty || message.thoughts != nil)) ||
                   (message.role == .user && !message.content.isEmpty) {
                    Task { @MainActor in
                        showRawContentModal = true
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $showLongMessageSheet) {
            LongMessageDetailView(
                message: message
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showRawContentModal) {
            RawContentModalView(message: message)
                .presentationDetents([.medium, .large])
        }
    }

    private func copyMessagePart(_ text: String) {
        let cleanText = removeThinktags(from: text)
        
        #if os(macOS)
        if let pasteboard = NSPasteboard.general {
            pasteboard.clearContents()
            pasteboard.setString(cleanText, forType: .string)
        }
        #elseif os(iOS)
        UIPasteboard.general.string = cleanText
        #endif
        
        withAnimation {
            showCopyFeedback = true
        }
        
        // Hide the feedback after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopyFeedback = false
            }
        }
    }
    
    // Remove think tags from text if present
    private func removeThinktags(from text: String) -> String {
        guard text.hasPrefix("<think>") else { return text }
        
        // If the text has think tags, we need to clean it up
        if let endTagRange = text.range(of: "</think>") {
            // Get just the text after the closing think tag
            return String(text[endTagRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return text.replacingOccurrences(of: "<think>", with: "")
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

private struct LongMessageAttachmentView: View {
    let message: Message
    let isDarkMode: Bool
    let openAction: () -> Void

    private var wordCountText: String {
        let words = message.content.split { $0.isWhitespace || $0.isNewline }
        return "\(words.count) words"
    }

    private var previewText: String {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.prefix(180)
        return preview + (trimmed.count > 180 ? "…" : "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 6) {
                Text("Long Message")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Text(wordCountText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: openAction)
    }
}

private struct LongMessageDetailView: View {
    let message: Message

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                SelectableTextView(text: message.content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.backgroundPrimary)
            .navigationTitle("Long Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SelectableTextView(text: fullRawContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                VStack(spacing: 12) {
                    Button(action: copyAll) {
                        HStack {
                            Image(systemName: showCopyAllFeedback ? "checkmark" : "doc.on.doc")
                            Text(showCopyAllFeedback ? "Copied All!" : "Copy All")
                            Spacer()
                        }
                        .foregroundColor(isDarkMode ? .white : .black)
                        .padding()
                        .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if hasThoughts && !responseContent.isEmpty {
                        Button(action: copyResponse) {
                            HStack {
                                Image(systemName: showCopyResponseFeedback ? "checkmark" : "text.quote")
                                Text(showCopyResponseFeedback ? "Copied Response!" : "Copy Response")
                                Spacer()
                            }
                            .foregroundColor(isDarkMode ? .white : .black)
                            .padding()
                            .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if hasThoughts {
                        Button(action: copyThoughts) {
                            HStack {
                                Image(systemName: showCopyThoughtsFeedback ? "checkmark" : "brain")
                                Text(showCopyThoughtsFeedback ? "Copied Thoughts!" : "Copy Thoughts")
                                Spacer()
                            }
                            .foregroundColor(isDarkMode ? .white : .black)
                            .padding()
                            .background(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding()
                .background(isDarkMode ? Color.backgroundPrimary : Color(UIColor.systemBackground))
            }
            .background(isDarkMode ? Color.backgroundPrimary : Color(UIColor.systemBackground))
            .navigationTitle("Raw Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
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

/// Cached markdown themes to avoid recreation on every render
private struct MarkdownThemeCache {
    static let darkTheme = createTheme(isDarkMode: true)
    static let lightTheme = createTheme(isDarkMode: false)
    static let userDarkTheme = createTheme(
        isDarkMode: true,
        textColor: Color.userMessageForegroundDark
    )
    static let userLightTheme = createTheme(
        isDarkMode: false,
        textColor: Color.userMessageForegroundLight
    )
    
    static func getTheme(isDarkMode: Bool) -> MarkdownUI.Theme {
        isDarkMode ? darkTheme : lightTheme
    }
    
    static func getUserTheme(isDarkMode: Bool) -> MarkdownUI.Theme {
        isDarkMode ? userDarkTheme : userLightTheme
    }
    
    private static func createTheme(isDarkMode: Bool, textColor: Color? = nil) -> MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                FontFamily(.system(.default))
                FontSize(.em(1.0))
                ForegroundColor(textColor ?? (isDarkMode ? .white : Color.black.opacity(0.8)))
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 12)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            }
            .codeBlock { configuration in
                SimpleCodeBlockView(
                    configuration: configuration,
                    isDarkMode: isDarkMode
                )
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 20, bottom: 10)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.75))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 16, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.5))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 14, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.25))
                    }
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontStyle(.italic)
                        ForegroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .markdownMargin(top: 8, bottom: 8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.2)))
                }
            }
    }
}

/// A view that renders Markdown content using the MarkdownUI library.
struct MarkdownText: View {
    let content: String
    let isDarkMode: Bool
    let horizontalPadding: CGFloat

    init(content: String, isDarkMode: Bool, horizontalPadding: CGFloat = 0) {
        self.content = content
        self.isDarkMode = isDarkMode
        self.horizontalPadding = horizontalPadding
    }

    var body: some View {
        Markdown(content)
            .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
            .padding(.horizontal, horizontalPadding)
            .environment(\.colorScheme, isDarkMode ? .dark : .light)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A specialized markdown text view that properly handles width constraints
struct AdaptiveMarkdownText: View {
    let content: String
    let isDarkMode: Bool
    let horizontalPadding: CGFloat

    init(content: String, isDarkMode: Bool, horizontalPadding: CGFloat = 0) {
        self.content = content
        self.isDarkMode = isDarkMode
        self.horizontalPadding = horizontalPadding
    }

    var body: some View {
        Markdown(content)
            .markdownTheme(MarkdownThemeCache.getUserTheme(isDarkMode: isDarkMode))
            .padding(.horizontal, horizontalPadding)
            .environment(\.colorScheme, .dark)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CollapsibleThinkingBox: View {
    let messageId: String
    let thinkingText: String
    let isDarkMode: Bool
    let isCollapsible: Bool
    let isStreaming: Bool
    let generationTimeSeconds: Double?
    let messageCollapsed: Bool

    @State private var isCollapsed: Bool
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel

    init(
        messageId: String,
        thinkingText: String,
        isDarkMode: Bool,
        isCollapsible: Bool,
        isStreaming: Bool,
        generationTimeSeconds: Double?,
        messageCollapsed: Bool
    ) {
        self.messageId = messageId
        self.thinkingText = thinkingText
        self.isDarkMode = isDarkMode
        self.isCollapsible = isCollapsible
        self.isStreaming = isStreaming
        self.generationTimeSeconds = generationTimeSeconds
        self.messageCollapsed = messageCollapsed
        _isCollapsed = State(initialValue: messageCollapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if let tableView = findTableView() {
                    UIView.performWithoutAnimation {
                        isCollapsed.toggle()
                        viewModel.setThoughtsCollapsed(for: messageId, collapsed: isCollapsed)
                        tableView.beginUpdates()
                        tableView.endUpdates()
                    }
                } else {
                    isCollapsed.toggle()
                    viewModel.setThoughtsCollapsed(for: messageId, collapsed: isCollapsed)
                }
            }) {
                HStack {
                    Image("tin")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                    HStack(spacing: 4) {
                        if let seconds = generationTimeSeconds {
                            Text("Thought")
                                .font(.system(size: 16))
                                .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                            Text("for \(String(format: "%.1f", seconds))s")
                                .font(.subheadline)
                                .foregroundColor(isDarkMode ? .white.opacity(0.7) : Color.black.opacity(0.6))
                        } else if isStreaming {
                            Text("Thinking")
                                .font(.system(size: 16))
                                .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                            InlineLoadingDotsView(isDarkMode: isDarkMode)
                        } else {
                            Text("Thinking")
                                .font(.system(size: 16))
                                .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isCollapsed ? 0 : -180))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .frame(maxWidth: .infinity)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()

                    Text(thinkingText)
                        .font(.system(.body))
                        .foregroundColor(isDarkMode ? .white.opacity(0.9) : Color.black.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .animation(nil, value: isCollapsed)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .clipped()
        .preference(key: ThinkingBoxExpansionPreferenceKey.self, value: !isCollapsed ? messageId : nil)
        .onChange(of: isStreaming) { oldValue, newValue in
        }
        .onChange(of: messageCollapsed) { _, newValue in
            if newValue != isCollapsed {
                UIView.performWithoutAnimation {
                    isCollapsed = newValue
                }
            }
        }
    }

    private func findTableView() -> UITableView? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return nil
        }

        func findTableView(in view: UIView) -> UITableView? {
            if let tableView = view as? UITableView {
                return tableView
            }
            for subview in view.subviews {
                if let found = findTableView(in: subview) {
                    return found
                }
            }
            return nil
        }

        return findTableView(in: window)
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
    }
}

struct PulsingAnimation: ViewModifier {
    let delay: Double
    @State private var isPulsing = false
    
    func body(content: Content) -> some View {
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

struct MessageActionsView: View {
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel
    
    var body: some View {
        EmptyView() // Placeholder - replace with actual content when needed
    }
}

/// A simplified code block view without syntax highlighting
struct SimpleCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    let isDarkMode: Bool
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel
    @State private var showCopyFeedback = false
    
    private var headerBackgroundColor: Color {
        isDarkMode ? Color.black.opacity(0.3) : Color.gray.opacity(0.1)
    }
    
    private var blockBackgroundColor: Color {
        isDarkMode ? Color.black.opacity(0.2) : Color.gray.opacity(0.05)
    }
    
    private var borderColor: Color {
        isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with language and copy button
            HStack {
                Text(configuration.language?.lowercased() ?? "plain text")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : Color.black.opacity(0.6))
                    .tracking(0.3)
                Spacer()

                Button(action: copyAction) {
                    Image(systemName: showCopyFeedback ? "checkmark" : "clipboard")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(showCopyFeedback ? .green : (isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(headerBackgroundColor)

            Divider()
            
            // Simple code content view without syntax highlighting
            ScrollView(.horizontal, showsIndicators: true) {
                Text(configuration.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                    .padding(8)
            }
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.85)
        .background(blockBackgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
        .markdownMargin(top: .em(0.5), bottom: .em(0.8))
    }
    
    private func copyAction() {
        #if os(macOS)
        if let pasteboard = NSPasteboard.general {
            pasteboard.clearContents()
            pasteboard.setString(configuration.content, forType: .string)
        }
        #elseif os(iOS)
        UIPasteboard.general.string = configuration.content
        #endif
        
        withAnimation {
            showCopyFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopyFeedback = false
            }
        }
    }
}

// Make sure the CodeBlockConfiguration is Equatable for .task(id:) to work correctly
extension CodeBlockConfiguration: @retroactive Equatable {
    public static func == (lhs: CodeBlockConfiguration, rhs: CodeBlockConfiguration) -> Bool {
        lhs.language == rhs.language && lhs.content == rhs.content
    }
}

struct ChunkedContentView: View {
    let chunks: [ContentChunk]
    let isDarkMode: Bool
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunks) { chunk in
                ChunkView(chunk: chunk, isDarkMode: isDarkMode, isStreaming: isStreaming)
            }
        }
    }
}

struct ChunkView: View, Equatable {
    let chunk: ContentChunk
    let isDarkMode: Bool
    let isStreaming: Bool

    static func == (lhs: ChunkView, rhs: ChunkView) -> Bool {
        if lhs.chunk.isComplete && rhs.chunk.isComplete {
            return lhs.chunk.id == rhs.chunk.id && lhs.isDarkMode == rhs.isDarkMode
        }
        return lhs.chunk.id == rhs.chunk.id &&
               lhs.chunk.isComplete == rhs.chunk.isComplete &&
               lhs.chunk.content == rhs.chunk.content &&
               lhs.isDarkMode == rhs.isDarkMode &&
               lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        LaTeXMarkdownView(
            content: chunk.content,
            isDarkMode: isDarkMode,
            isStreaming: chunk.isComplete ? false : isStreaming
        )
        .equatable()
        .id(chunk.id)
    }
}

struct ErrorMessageView: View {
    let errorMessage: String
    let isDarkMode: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 20))
                
                Text("Error")
                    .font(.headline)
                    .foregroundColor(.red)
                
                Spacer()
            }
            
            Text(errorMessage)
                .font(.subheadline)
                .foregroundColor(isDarkMode ? .white : .black)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
