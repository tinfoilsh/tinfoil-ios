//
//  OptimizedChatListView.swift
//  TinfoilChat
//
//  Optimized UIKit-based ScrollView implementation for chat
//

import SwiftUI

struct OptimizedChatListView: View {
    let messages: [Message]
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var messageText: String

    @State private var isAtBottom = true
    @State private var userHasScrolled = false
    @State private var isKeyboardVisible = false
    @State private var estimatedStreamingHeight: CGFloat = 0
    @State private var lastAIMessageID: String? = nil
    @State private var scrollTrigger = UUID()
    @State private var keyboardObservers: [Any] = []

    private var archivedMessagesStartIndex: Int {
        max(0, messages.count - settings.maxMessages)
    }

    private var visibleMessages: ArraySlice<Message> {
        let startIndex = max(0, messages.count - 100)
        return messages[startIndex..<messages.count]
    }

    var body: some View {
        UIKitScrollView(
            messages: messages,
            visibleMessages: Array(visibleMessages),
            archivedMessagesStartIndex: archivedMessagesStartIndex,
            isDarkMode: isDarkMode,
            isLoading: isLoading,
            onRequestSignIn: onRequestSignIn,
            viewModel: viewModel,
            estimatedStreamingHeight: $estimatedStreamingHeight,
            lastAIMessageID: $lastAIMessageID,
            isAtBottom: $isAtBottom,
            userHasScrolled: $userHasScrolled,
            scrollTrigger: scrollTrigger
        )
        .background(Color.chatBackground(isDarkMode: isDarkMode))
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom && !messages.isEmpty && !isKeyboardVisible {
                Group {
                    if #available(iOS 26, *) {
                        Button(action: {
                            userHasScrolled = false
                            viewModel.isScrollInteractionActive = false
                            scrollTrigger = UUID()
                        }) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: Constants.UI.scrollToBottomButtonSize, height: Constants.UI.scrollToBottomButtonSize)
                        }
                        .buttonStyle(.glass)
                        .clipShape(Circle())
                    } else {
                        Button(action: {
                            userHasScrolled = false
                            viewModel.isScrollInteractionActive = false
                            scrollTrigger = UUID()
                        }) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.gray.opacity(0.8))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.bottom, 16)
                .padding(.trailing, 16)
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MessageInputView(
                messageText: $messageText,
                viewModel: viewModel,
                isKeyboardVisible: isKeyboardVisible
            )
            .environmentObject(viewModel.authManager ?? AuthManager())
            .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                HStack {
                    Spacer()
                    view.frame(maxWidth: 600)
                    Spacer()
                }
            }
        }
        .onAppear {
            setupKeyboardObservers()
        }
        .onDisappear {
            removeKeyboardObservers()
            viewModel.isScrollInteractionActive = false
        }
        .onChange(of: messages.count) { oldCount, newCount in
            if newCount > oldCount {
                let newMessages = messages.suffix(newCount - oldCount)
                let hasUserMessage = newMessages.contains { $0.role == .user }
                let wasInitialLoad = oldCount == 0

                if !hasUserMessage && !wasInitialLoad {
                    estimatedStreamingHeight = 0
                }

                if hasUserMessage || wasInitialLoad {
                    userHasScrolled = false
                    viewModel.isScrollInteractionActive = false
                    scrollTrigger = UUID()
                }
            }
        }
        .onChange(of: viewModel.currentChat?.createdAt) { _, _ in
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false

            let isNewEmptyChat = viewModel.currentChat?.isBlankChat ?? true

            if !isNewEmptyChat {
                scrollTrigger = UUID()
                isAtBottom = true
            } else {
                isAtBottom = true
            }
        }
        .onChange(of: viewModel.scrollToBottomTrigger) { _, _ in
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false
            scrollTrigger = UUID()
        }
    }

    private func setupKeyboardObservers() {
        let showObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                isKeyboardVisible = true
            }
        }

        let hideObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                isKeyboardVisible = false
            }
        }

        keyboardObservers = [showObserver, hideObserver]
    }

    private func removeKeyboardObservers() {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers.removeAll()
    }
}

// MARK: - UIKit ScrollView

struct UIKitScrollView: UIViewRepresentable {
    let messages: [Message]
    let visibleMessages: [Message]
    let archivedMessagesStartIndex: Int
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Binding var estimatedStreamingHeight: CGFloat
    @Binding var lastAIMessageID: String?
    @Binding var isAtBottom: Bool
    @Binding var userHasScrolled: Bool
    let scrollTrigger: UUID

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.clipsToBounds = false

        let hostingController = UIHostingController(rootView: AnyView(contentView()))
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.clipsToBounds = false
        hostingController.sizingOptions = [.intrinsicContentSize]

        scrollView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        context.coordinator.hostingController = hostingController
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self

        let messageCountChanged = context.coordinator.lastMessageCount != messages.count
        if messageCountChanged {
            context.coordinator.lastMessageCount = messages.count
        }

        let isLoadingChanged = context.coordinator.lastIsLoading != isLoading
        if isLoadingChanged {
            context.coordinator.lastIsLoading = isLoading
        }

        if isAtBottom || !userHasScrolled || messageCountChanged || isLoadingChanged {
            context.coordinator.hostingController?.rootView = AnyView(contentView())

            DispatchQueue.main.async {
                context.coordinator.hostingController?.view.invalidateIntrinsicContentSize()
                context.coordinator.hostingController?.view.setNeedsLayout()
            }
        }

        if context.coordinator.lastScrollTrigger != scrollTrigger {
            context.coordinator.lastScrollTrigger = scrollTrigger
            DispatchQueue.main.async {
                context.coordinator.scrollToBottom(animated: !self.messages.isEmpty)
            }
        }

        DispatchQueue.main.async {
            context.coordinator.checkIfAtBottom()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func contentView() -> some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                if let authManager = viewModel.authManager {
                    WelcomeView(
                        isDarkMode: isDarkMode,
                        authManager: authManager,
                        onRequestSignIn: onRequestSignIn
                    )
                    .padding(.vertical, 16)
                    .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 0)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { relativeIndex, message in
                    let actualIndex = messages.count - visibleMessages.count + relativeIndex

                    VStack(spacing: 0) {
                        if actualIndex == archivedMessagesStartIndex && archivedMessagesStartIndex > 0 {
                            HStack(spacing: 8) {
                                Rectangle()
                                    .frame(height: 1)
                                    .foregroundColor(.gray)
                                Text("archived")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 12))
                                Rectangle()
                                    .frame(height: 1)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 24)
                        }

                        let isStreamingMessage = actualIndex == messages.count - 1 && isLoading
                        let isAIMessage = message.role == .assistant

                        if isStreamingMessage {
                            StreamingMessageContainer(
                                message: message,
                                isDarkMode: isDarkMode,
                                isLoading: true,
                                estimatedHeight: $estimatedStreamingHeight,
                                shouldPauseUpdates: !isAtBottom,
                                messageIndex: actualIndex
                            )
                            .id(message.id)
                            .padding(.vertical, 8)
                            .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 8)
                            .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                                view.frame(maxWidth: 900)
                                    .frame(maxWidth: .infinity)
                            }
                            .onAppear {
                                lastAIMessageID = message.id
                            }
                        } else {
                            MessageView(
                                message: message,
                                isDarkMode: isDarkMode,
                                isLastMessage: actualIndex == messages.count - 1,
                                isLoading: false,
                                messageIndex: actualIndex
                            )
                            .id(message.id)
                            .if(isAIMessage && actualIndex == messages.count - 1) { view in
                                view.onAppear {
                                    lastAIMessageID = message.id
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 8)
                            .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                                view.frame(maxWidth: 900)
                                    .frame(maxWidth: .infinity)
                            }
                            .opacity(actualIndex < archivedMessagesStartIndex ? 0.6 : 1.0)
                        }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity)
        .environmentObject(viewModel)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: UIKitScrollView
        var hostingController: UIHostingController<AnyView>?
        weak var scrollView: UIScrollView?
        var lastScrollTrigger: UUID?
        var lastMessageCount: Int = 0
        var lastIsLoading: Bool = false
        private var isDragging = false

        init(_ parent: UIKitScrollView) {
            self.parent = parent
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            checkIfAtBottom()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isDragging = true
            parent.userHasScrolled = true
            parent.viewModel.isScrollInteractionActive = true
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            isDragging = false
            if !decelerate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.parent.viewModel.isScrollInteractionActive = false
                }
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.parent.viewModel.isScrollInteractionActive = false
            }
        }

        func scrollToBottom(animated: Bool) {
            guard let scrollView = scrollView else { return }

            scrollView.setContentOffset(scrollView.contentOffset, animated: false)

            let bottomOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)

            if animated {
                UIView.animate(withDuration: 0.2) {
                    scrollView.contentOffset = CGPoint(x: 0, y: bottomOffset)
                }
            } else {
                scrollView.contentOffset = CGPoint(x: 0, y: bottomOffset)
            }
        }

        func checkIfAtBottom() {
            guard let scrollView = scrollView else { return }
            guard scrollView.window != nil else { return }

            let bottomOffset = scrollView.contentSize.height - scrollView.bounds.height
            let currentOffset = scrollView.contentOffset.y

            let slack: CGFloat = 150
            let isVisible = (bottomOffset - currentOffset) <= slack

            if parent.isAtBottom != isVisible {
                DispatchQueue.main.async {
                    self.parent.isAtBottom = isVisible
                    self.parent.viewModel.isAtBottom = isVisible
                    if isVisible {
                        self.parent.userHasScrolled = false
                    }
                }
            }
        }
    }
}

// MARK: - Streaming Message Container

/// A container that pre-allocates space for streaming messages to prevent layout jumps
struct StreamingMessageContainer: View {
    let message: Message
    let isDarkMode: Bool
    let isLoading: Bool
    @Binding var estimatedHeight: CGFloat
    let shouldPauseUpdates: Bool
    let messageIndex: Int

    @State private var actualHeight: CGFloat = 0
    @State private var displayedMessage: Message

    init(message: Message, isDarkMode: Bool, isLoading: Bool, estimatedHeight: Binding<CGFloat>, shouldPauseUpdates: Bool, messageIndex: Int) {
        self.message = message
        self.isDarkMode = isDarkMode
        self.isLoading = isLoading
        self._estimatedHeight = estimatedHeight
        self.shouldPauseUpdates = shouldPauseUpdates
        self.messageIndex = messageIndex
        self._displayedMessage = State(initialValue: message)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Invisible spacer that maintains minimum height
            Color.clear
                .frame(height: estimatedHeight)

            // Actual message content - frozen when user scrolled away
            MessageView(
                message: displayedMessage,
                isDarkMode: isDarkMode,
                isLastMessage: true,
                isLoading: isLoading,
                messageIndex: messageIndex
            )
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            actualHeight = geometry.size.height
                            if estimatedHeight == 0 {
                                estimatedHeight = actualHeight
                            }
                        }
                        .onChange(of: geometry.size.height) { _, newHeight in
                            if !shouldPauseUpdates {
                                actualHeight = newHeight
                                estimatedHeight = newHeight
                            }
                        }
                }
            )
        }
        .onChange(of: shouldPauseUpdates) { _, paused in
            if !paused {
                // User scrolled back to bottom - resume live updates
                displayedMessage = message
            }
        }
        .onChange(of: message.content) { _, _ in
            // Update displayed message only when at bottom (not paused)
            if !shouldPauseUpdates {
                displayedMessage = message
            }
        }
        .onChange(of: message.isThinking) { _, _ in
            // Update displayed message when thinking state changes
            if !shouldPauseUpdates {
                displayedMessage = message
            }
        }
        .onChange(of: message.thoughts) { _, _ in
            // Update displayed message when thoughts change
            if !shouldPauseUpdates {
                displayedMessage = message
            }
        }
        .onChange(of: isLoading) { _, nowLoading in
            if !nowLoading {
                withAnimation(.easeOut(duration: 0.2)) {
                    estimatedHeight = actualHeight
                }
            }
        }
    }
}