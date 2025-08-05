//
//  MessageView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.
//

import SwiftUI
import MarkdownUI

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
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel
    @State private var showCopyFeedback = false
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                // Show the loading dots for a fresh streaming assistant response
                if message.role == .assistant &&
                    message.content.isEmpty &&
                    viewModel.isLoading &&
                    message.id == viewModel.messages.last?.id {
                    LoadingDotsView(isDarkMode: isDarkMode)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // If the message begins with the special think tag, parse and display it in a box
                else if let parsed = parsedMessageContent {
                    VStack(alignment: .leading, spacing: 4) {
                        CollapsibleThinkingBox(
                            messageId: message.id,
                            thinkingText: parsed.thinkingText,
                            isDarkMode: isDarkMode,
                            isCollapsible: message.content.contains("</think>"),
                            isStreaming: viewModel.isLoading && message.id == viewModel.messages.last?.id,
                            generationTimeSeconds: message.generationTimeSeconds
                        )
                        
                        // Remainder: text after </think> if present
                        if !parsed.remainderText.isEmpty {
                            MarkdownText(content: parsed.remainderText, isDarkMode: isDarkMode)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                
                // Otherwise display the message as before using Markdown rendering
                else if !message.content.isEmpty {
                    if message.streamError != nil {
                        // Error message display
                        ErrorMessageView(errorMessage: message.streamError!, isDarkMode: isDarkMode)
                    } else if message.role == .user {
                        AdaptiveMarkdownText(content: message.content, isDarkMode: isDarkMode)
                    } else {
                        MarkdownText(content: message.content, isDarkMode: isDarkMode)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(message.role == .user ? (isDarkMode ? Color.gray.opacity(0.3) : Color(hex: "#111827")) : nil)
            .cornerRadius(16)
            .modifier(MessageBubbleModifier(isUserMessage: message.role == .user))
            .contextMenu {
                if !message.content.isEmpty {
                    Button(action: copyMessage) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    
                    if let parsed = parsedMessageContent {
                        if !parsed.remainderText.isEmpty {
                            Button(action: { copyMessagePart(parsed.remainderText) }) {
                                Label("Copy Response", systemImage: "text.quote")
                            }
                        }
                        
                        Button(action: { copyMessagePart(parsed.thinkingText) }) {
                            Label("Copy Thinking", systemImage: "brain")
                        }
                    }
                }
            }
            .overlay(alignment: message.role == .user ? .leading : .trailing) {
                if showCopyFeedback {
                    copyFeedbackView
                }
            }
            
            if message.role == .assistant {
                Spacer()
            }
        }
        .padding(.horizontal, 4)
    }
    
    // Feedback view shown when text is copied
    private var copyFeedbackView: some View {
        Text("Copied!")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(8)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .padding(.horizontal, 8)
    }
    
    // Function to copy the entire message
    private func copyMessage() {
        copyMessagePart(message.content)
    }
    
    // Function to copy a specific part of the message
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
    
    /// If the message starts with "<think>", this computed property parses the text.
    /// It returns a tuple where:
    /// - thinkingText is the text between "<think>" and "</think>"
    /// - remainderText is any text after "</think>"
    ///
    /// This parsing is specifically designed to handle DeepSeek model responses which use
    /// special <think></think> tags to denote the model's internal reasoning process.
    /// The parser handles both complete responses (with closing tag) and streaming
    /// responses (where the closing tag might not have arrived yet).
    ///
    /// Example:
    /// Input: "<think>Let me analyze this...</think>The answer is 42."
    /// Output: (thinkingText: "Let me analyze this...", remainderText: "The answer is 42.")
    private var parsedMessageContent: (thinkingText: String, remainderText: String)? {
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
                    // Assistant messages get full width
                    .frame(maxWidth: max(60, UIScreen.main.bounds.width), alignment: .leading)
            }
        }
    }
}

/// Creates a custom markdown theme based on dark mode setting
private func createMarkdownTheme(isDarkMode: Bool) -> MarkdownUI.Theme {
    MarkdownUI.Theme.gitHub
        .text {
            FontFamily(.system(.default))
            FontSize(.em(1.0))
            ForegroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
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
            .markdownTheme(createMarkdownTheme(isDarkMode: isDarkMode))
            .padding(.horizontal, horizontalPadding)
            .environment(\.colorScheme, isDarkMode ? .dark : .light)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
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
            .markdownTheme(createMarkdownTheme(isDarkMode: true)) // Always use dark theme for user messages
            .padding(.horizontal, horizontalPadding)
            .environment(\.colorScheme, .dark)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// New collapsible thinking box that always takes full width and left-aligns its text.
struct CollapsibleThinkingBox: View {
    let messageId: String
    let thinkingText: String
    let isDarkMode: Bool
    let isCollapsible: Bool
    let isStreaming: Bool
    let generationTimeSeconds: Double?
    
    @State private var isCollapsed: Bool = true
    @EnvironmentObject var viewModel: TinfoilChat.ChatViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header is always visible
            Button(action: {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                    isCollapsed.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                    HStack(spacing: 4) {
                        if let seconds = generationTimeSeconds {
                            Text("Thought")
                                .font(.system(size: 16))
                                .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                            Text("for \(String(format: "%.1f", seconds))s")
                                .font(.subheadline)
                                .foregroundColor(isDarkMode ? .white.opacity(0.7) : Color.black.opacity(0.6))
                        } else {
                            Text("Thinking...")
                                .font(.system(size: 16))
                                .foregroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isCollapsed ? 0 : -180))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCollapsed)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .frame(maxWidth: .infinity)
            
            // Content area with divider - always in the view hierarchy but height is zero when collapsed
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                
                NumberedThoughtLinesView(text: thinkingText, isDarkMode: isDarkMode)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            .frame(height: isCollapsed ? 0 : nil)
            .opacity(isCollapsed ? 0 : 1)
            .clipped()
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .clipped()
        .onAppear {
            withAnimation(.spring()) {
                // Initialize collapsed state - always start collapsed
                isCollapsed = true
            }
        }
        // Set preference when thinking box expansion state changes
        .preference(key: ThinkingBoxExpansionPreferenceKey.self, value: !isCollapsed ? messageId : nil)
        .onChange(of: isStreaming) { oldValue, newValue in
            // Keep the box collapsed regardless of streaming state changes
            // User can manually expand/collapse as needed
        }
        .onChange(of: isCollapsible) { oldValue, newValue in
            // If the box just became collapsible (streaming ended)
            if newValue && !oldValue {
                withAnimation(.spring()) {
                    isCollapsed = true // Auto-collapse
                }
            }
        }
    }
}

/// A custom view that displays each line of text with a numbered label
/// and a vertical connector extending to subsequent lines. We treat
/// double newlines (\n\n) as actual line breaks and convert single
/// newlines (\n) into spaces so they don't split lines.
struct NumberedThoughtLinesView: View {
    let text: String
    let isDarkMode: Bool
    
    @State private var heights: [Int: CGFloat] = [:]
    @State private var totalHeight: CGFloat = 0

    var body: some View {
        let replaced = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            // Convert single newlines to spaces, but preserve double newlines as paragraph breaks
            // This regex pattern matches:
            // ([^\n]) - any character that isn't a newline (captured as group 1)
            // \n - a single newline
            // (?!\n) - negative lookahead: not followed by another newline
            // ([^\n]) - any character that isn't a newline (captured as group 2)
            // The replacement "$1 $2" joins the two captured groups with a space
            .replacingOccurrences(
                of: #"([^\n])\n(?!\n)([^\n])"#, 
                with: "$1 $2",
                options: .regularExpression
            )
        
        let lines = replaced.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 8) {
                    // Container for circle and line
                    ZStack(alignment: .top) {
                        // Vertical line for connection to next paragraph (if exists)
                        if i < lines.count - 1 {
                            Rectangle()
                                .fill(isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.2))
                                .frame(width: 2)
                                // Position the line to start from below the circle
                                // and extend down but not all the way to the next circle
                                .frame(height: max((heights[i] ?? 0) - 8, 0)) // Reduced height to prevent overlap
                                .offset(y: 24) // Start below the circle
                        }
                        
                        // Circle with number (positioned at the top)
                        ZStack {
                            Circle()
                                .fill(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
                                .frame(width: 20, height: 20)
                            
                            Text("\(i+1)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(isDarkMode ? .white : .black)
                        }
                    }
                    .frame(width: 20)
                    
                    // Text content
                    MarkdownText(content: lines[i], isDarkMode: isDarkMode, horizontalPadding: 0)
                        .padding(.top, 2)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.onAppear {
                                    if geometry.size.height.isFinite {
                                        heights[i] = geometry.size.height
                                        calculateTotalHeight()
                                    }
                                }.onChange(of: geometry.size.height) { oldValue, newValue in
                                    // Update height when content changes and value is valid
                                    if abs(oldValue - newValue) > 1 && newValue.isFinite {
                                        heights[i] = newValue
                                        calculateTotalHeight()
                                    }
                                }
                            }
                        )
                }
                // Add spacing between paragraphs
                .padding(.bottom, i < lines.count - 1 ? 24 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
    
    // Calculate the total height of all paragraphs for positioning
    private func calculateTotalHeight() {
        var total: CGFloat = 0
        for i in heights.keys.sorted() {
            if let height = heights[i], height.isFinite {
                total += height + (i < heights.count - 1 ? 16 : 0) // Add spacing between paragraphs
            }
        }
        self.totalHeight = total
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
                    .textSelection(.enabled)
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

// At the end of the file, add the ErrorMessageView
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
