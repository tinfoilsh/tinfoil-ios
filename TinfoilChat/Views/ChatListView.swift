//
//  ChatListView.swift
//  TinfoilChat
//
//  UITableView-based chat list wrapper
//

import SwiftUI

struct ChatListView: View {
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var messageText: String

    @State private var isAtBottom = true
    @State private var userHasScrolled = false
    @State private var isKeyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollTrigger = UUID()
    @State private var tableOpacity = 1.0

    private var messages: [Message] {
        viewModel.messages
    }

    private var archivedMessagesStartIndex: Int {
        max(0, messages.count - settings.maxMessages)
    }

    var body: some View {
        MessageTableView(
            archivedMessagesStartIndex: archivedMessagesStartIndex,
            isDarkMode: isDarkMode,
            isLoading: isLoading,
            onRequestSignIn: onRequestSignIn,
            viewModel: viewModel,
            isAtBottom: $isAtBottom,
            userHasScrolled: $userHasScrolled,
            scrollTrigger: scrollTrigger,
            tableOpacity: $tableOpacity,
            keyboardHeight: keyboardHeight
        )
        .opacity(tableOpacity)
        .background(Color.chatBackground(isDarkMode: isDarkMode))
        .overlay(alignment: .bottom) {
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

                if hasUserMessage || wasInitialLoad {
                    userHasScrolled = false
                    viewModel.isScrollInteractionActive = false
                    scrollTrigger = UUID()
                }
            }
        }
        .onChange(of: viewModel.currentChat?.id) { oldId, newId in
            // Only reset scroll and fade if we're actually switching to a different chat
            guard oldId != newId else { return }

            userHasScrolled = false
            viewModel.isScrollInteractionActive = false

            let isNewEmptyChat = viewModel.currentChat?.isBlankChat ?? true

            if !isNewEmptyChat {
                tableOpacity = 0
                scrollTrigger = UUID()
                isAtBottom = true
            } else {
                tableOpacity = 1.0
                isAtBottom = true
            }
        }
    }

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                let keyboardHeight = keyboardFrame.height
                withAnimation(.easeOut(duration: 0.25)) {
                    isKeyboardVisible = true
                    self.keyboardHeight = keyboardHeight
                }
            }
        }

        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                isKeyboardVisible = false
                keyboardHeight = 0
            }
        }
    }

    private func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }
}
