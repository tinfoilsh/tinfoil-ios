//
//  MessageTableView.swift
//  TinfoilChat
//
//  UITableView-based message list with cell reuse
//

import SwiftUI
import Textual
import ObjectiveC

struct MessageTableView: UIViewRepresentable {
    let messages: [Message]
    let recoveryDraftTurnIds: Set<String>
    let archivedMessagesStartIndex: Int
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Binding var isAtBottom: Bool
    @Binding var userHasScrolled: Bool
    let scrollTrigger: UUID
    let scrollToUserTrigger: UUID
    @Binding var tableOpacity: Double
    let keyboardHeight: CGFloat

    private func hasRecoveryDraft(_ message: Message) -> Bool {
        message.turnId.map { recoveryDraftTurnIds.contains($0) } ?? false
    }

    private var usesStreamingLayout: Bool {
        guard let lastMessage = messages.last else { return isLoading }
        return isLoading || hasRecoveryDraft(lastMessage)
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.keyboardDismissMode = .onDrag
        tableView.allowsSelection = false
        tableView.estimatedRowHeight = Constants.HeightEstimation.fallbackHeight
        tableView.rowHeight = UITableView.automaticDimension
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.clipsToBounds = false

        if #available(iOS 15.0, *) {
            tableView.isPrefetchingEnabled = true
        }

        context.coordinator.tableView = tableView
        tableView.accessibilityCustomRotors = [context.coordinator.makeMessagesRotor()]

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleBackgroundTap)
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        tableView.addGestureRecognizer(tapGesture)

        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.parent = self

        let keyboardHeightChanged = context.coordinator.lastKeyboardHeight != keyboardHeight
        if keyboardHeightChanged {
            let wasAtBottom = context.coordinator.parent.isAtBottom
            context.coordinator.lastKeyboardHeight = keyboardHeight
            context.coordinator.isKeyboardTransitioning = true

            if wasAtBottom && keyboardHeight > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    context.coordinator.scrollToBottom(animated: true)
                    context.coordinator.isKeyboardTransitioning = false
                }
            } else {
                DispatchQueue.main.async {
                    context.coordinator.isKeyboardTransitioning = false
                }
            }
        }

        let currentChatId = viewModel.currentChat?.id
        let previousChatId = context.coordinator.lastChatId
        let chatIdChanged = previousChatId != currentChatId

        // Detect ID conversion (temp → permanent) by checking if message IDs match
        // This is more reliable than checking wrappers since wrappers only exist for rendered cells
        let currentMessageIds = Set(messages.map { $0.id })
        let isIdConversion = chatIdChanged && !currentMessageIds.isEmpty &&
            currentMessageIds == context.coordinator.lastMessageIds

        // Track which row is streaming synchronously, before any reload below
        // measures cells. A queued message dispatched right as a stream ends
        // can move `isLoading` false -> true and append rows within a single
        // update, so the finished message's wrapper still claims to be the
        // streaming last row when the reload measures it (wrapper updates are
        // deferred a runloop tick). The cell's streaming buffer keys off this
        // coordinator value instead, so the finished row measures at its
        // collapsed height immediately and can't overlap the rows added after
        // it. The stale wrapper's buffer state and cached height go with it.
        let previousStreamingMessageId = context.coordinator.streamingMessageId
        context.coordinator.streamingMessageId = usesStreamingLayout ? messages.last?.id : nil
        if let staleId = previousStreamingMessageId,
           staleId != context.coordinator.streamingMessageId,
           let staleWrapper = context.coordinator.messageWrappers[staleId] {
            staleWrapper.resetBuffer()
            context.coordinator.messageHeightCache.removeValue(forKey: staleId)
        }

        if chatIdChanged {
            context.coordinator.lastChatId = currentChatId
            context.coordinator.preservedOffsetAfterStreaming = nil
            context.coordinator.isCollapsingStreamingBuffer = false

            if !isIdConversion {
                // Sync the loading flag on real chat switches so the
                // buffer-collapse path below never runs for a switch away
                // from a chat that is still streaming; it only describes a
                // stream ending in place. ID conversions keep the prior value:
                // the same conversation stays on screen with its wrappers
                // retained, so a stream that ends across the conversion must
                // still collapse its buffer through the normal path.
                context.coordinator.lastUsesStreamingLayout = usesStreamingLayout
                context.coordinator.messageWrappers.removeAll()
                context.coordinator.shownMessageIds.removeAll()

                // Drop any streaming inset left behind by the previous chat,
                // and reset a blank chat to the top since no scroll trigger
                // will fire to position it.
                UIView.performWithoutAnimation {
                    tableView.contentInset.bottom = 0
                    tableView.verticalScrollIndicatorInsets.bottom = 0
                    if messages.isEmpty {
                        tableView.contentOffset.y = -tableView.adjustedContentInset.top
                    }
                }
            }
            context.coordinator.lastMessageIds = currentMessageIds
        } else if currentMessageIds != context.coordinator.lastMessageIds {
            // Message IDs changed without chat ID changing (e.g., regenerate,
            // edit, archive cleanup).
            let idsWereReplaced = !currentMessageIds.isEmpty &&
                                  !context.coordinator.lastMessageIds.isEmpty &&
                                  currentMessageIds.isDisjoint(with: context.coordinator.lastMessageIds)

            if idsWereReplaced {
                // All message IDs are different - clear stale wrappers
                context.coordinator.messageWrappers.removeAll()
                context.coordinator.shownMessageIds.removeAll()
                context.coordinator.heightCache.removeAll()
                context.coordinator.messageHeightCache.removeAll()
                context.coordinator.contentEstimateCache.removeAll()
            } else {
                // Drop any wrappers and cached heights that belong to messages
                // that no longer exist. Without this, long sessions accumulate
                // ObservableMessageWrapper instances - each holding seven
                // @Published values - which inflates SwiftUI's environment
                // property list and shows up as long compareLists / env-diff
                // hangs in production.
                let removedIds = context.coordinator.lastMessageIds.subtracting(currentMessageIds)
                if !removedIds.isEmpty {
                    for messageId in removedIds {
                        context.coordinator.messageWrappers.removeValue(forKey: messageId)
                        context.coordinator.shownMessageIds.remove(messageId)
                        context.coordinator.messageHeightCache.removeValue(forKey: messageId)
                        context.coordinator.contentEstimateCache.removeValue(forKey: messageId)
                    }
                    context.coordinator.heightCache.removeAll()
                }
            }
            context.coordinator.lastMessageIds = currentMessageIds
            tableView.reloadData()
        }

        let isDarkModeChanged = context.coordinator.lastIsDarkMode != isDarkMode
        let messageCountChanged = context.coordinator.lastMessageCount != messages.count

        if isDarkModeChanged {
            context.coordinator.lastIsDarkMode = isDarkMode
            DispatchQueue.main.async {
                for wrapper in context.coordinator.messageWrappers.values {
                    wrapper.isDarkMode = isDarkMode
                }
            }
        }

        if messageCountChanged || (chatIdChanged && !isIdConversion) {
            context.coordinator.lastMessageCount = messages.count
            context.coordinator.heightCache.removeAll()
            tableView.reloadData()
        } else if usesStreamingLayout && !messages.isEmpty {
            // During streaming, update the last message wrapper directly
            if let lastMessage = messages.last,
               let wrapper = context.coordinator.messageWrappers[lastMessage.id] {
                let lastMessageId = lastMessage.id
                if hasRecoveryDraft(lastMessage) {
                    context.coordinator.heightCache.removeValue(
                        forKey: IndexPath(row: messages.count - 1, section: 0)
                    )
                    context.coordinator.messageHeightCache.removeValue(
                        forKey: lastMessage.id
                    )
                    context.coordinator.contentEstimateCache.removeValue(
                        forKey: lastMessage.id
                    )
                }

                let isArchived = messages.count - 1 < archivedMessagesStartIndex
                let showArchiveSeparator = messages.count - 1 == archivedMessagesStartIndex && archivedMessagesStartIndex > 0

                // Update multiplier synchronously to prevent race condition:
                // updateUIView is called on every streaming token, and if we defer
                // the update to DispatchQueue.main.async, many calls will read the
                // stale multiplier and each queue a +10 increment, causing it to
                // explode to thousands.
                let screenHeight = UIScreen.main.bounds.height
                let needsBufferExtension = wrapper.extendBufferIfNeeded(screenHeight: screenHeight)

                let coordinator = context.coordinator
                DispatchQueue.main.async {
                    // The chat may have been swapped (e.g. a new chat created on
                    // foregrounding) between enqueue and execution; updating the
                    // stale wrapper or recalculating heights against the old row
                    // set would desync the table from its datasource.
                    guard coordinator.lastChatId == currentChatId,
                          coordinator.streamingMessageId == lastMessageId,
                          let currentMessage = coordinator.parent.messages.last,
                          currentMessage.id == lastMessageId
                    else {
                        return
                    }

                    wrapper.update(
                        message: currentMessage,
                        isDarkMode: coordinator.parent.isDarkMode,
                        isLastMessage: true,
                        isLoading: coordinator.parent.isLoading,
                        hasRecoveryDraft: coordinator.parent.hasRecoveryDraft(currentMessage),
                        isArchived: isArchived,
                        showArchiveSeparator: showArchiveSeparator,
                        messageIndex: coordinator.parent.messages.count - 1
                    )

                    if needsBufferExtension && !coordinator.isKeyboardTransitioning &&
                        tableView.numberOfRows(inSection: 0) == coordinator.parent.messages.count {
                        tableView.beginUpdates()
                        tableView.endUpdates()
                    }
                }
            }
            for (index, message) in messages.dropLast().enumerated() {
                guard hasRecoveryDraft(message),
                      let wrapper = context.coordinator.messageWrappers[message.id]
                else {
                    continue
                }
                context.coordinator.heightCache.removeValue(
                    forKey: IndexPath(row: index, section: 0)
                )
                context.coordinator.messageHeightCache.removeValue(forKey: message.id)
                context.coordinator.contentEstimateCache.removeValue(forKey: message.id)
                wrapper.update(
                    message: message,
                    isDarkMode: isDarkMode,
                    isLastMessage: false,
                    isLoading: false,
                    hasRecoveryDraft: true,
                    isArchived: index < archivedMessagesStartIndex,
                    showArchiveSeparator: index == archivedMessagesStartIndex
                        && archivedMessagesStartIndex > 0,
                    messageIndex: index
                )
            }
        } else {
            for (index, message) in messages.enumerated() {
                guard let wrapper = context.coordinator.messageWrappers[message.id] else {
                    continue
                }
                if hasRecoveryDraft(message) {
                    context.coordinator.heightCache.removeValue(
                        forKey: IndexPath(row: index, section: 0)
                    )
                    context.coordinator.messageHeightCache.removeValue(forKey: message.id)
                    context.coordinator.contentEstimateCache.removeValue(forKey: message.id)
                }
                wrapper.update(
                    message: message,
                    isDarkMode: isDarkMode,
                    isLastMessage: index == messages.count - 1,
                    isLoading: false,
                    hasRecoveryDraft: hasRecoveryDraft(message),
                    isArchived: index < archivedMessagesStartIndex,
                    showArchiveSeparator: index == archivedMessagesStartIndex
                        && archivedMessagesStartIndex > 0,
                    messageIndex: index
                )
            }
        }

        let streamingLayoutChanged =
            context.coordinator.lastUsesStreamingLayout != usesStreamingLayout
        context.coordinator.lastUsesStreamingLayout = usesStreamingLayout

        if streamingLayoutChanged && !usesStreamingLayout {
            let preservedOffset = tableView.contentOffset.y
            context.coordinator.preservedOffsetAfterStreaming = preservedOffset
            context.coordinator.isCollapsingStreamingBuffer = true
            context.coordinator.shouldScrollToBottomAfterLayout = false

            UIView.performWithoutAnimation {
                let temporaryInset = max(tableView.contentInset.bottom, preservedOffset + tableView.bounds.height)
                tableView.contentInset.bottom = temporaryInset
                tableView.verticalScrollIndicatorInsets.bottom = temporaryInset
                tableView.contentOffset.y = preservedOffset
            }

            var finishedWrapper: ObservableMessageWrapper?

            // Streaming just ended - update the last message wrapper to reflect final state (including any errors)
            if let lastMessage = messages.last,
               let wrapper = context.coordinator.messageWrappers[lastMessage.id] {
                finishedWrapper = wrapper
                let isArchived = messages.count - 1 < archivedMessagesStartIndex
                let showArchiveSeparator = messages.count - 1 == archivedMessagesStartIndex && archivedMessagesStartIndex > 0
                wrapper.update(
                    message: lastMessage,
                    isDarkMode: isDarkMode,
                    isLastMessage: true,
                    isLoading: false,
                    hasRecoveryDraft: hasRecoveryDraft(lastMessage),
                    isArchived: isArchived,
                    showArchiveSeparator: showArchiveSeparator,
                    messageIndex: messages.count - 1
                )
            }

            // Collapsing the streaming buffer changes contentSize dramatically.
            // Preserve the user's exact reading position through that resize
            // rather than scrolling to the end. The buffer being removed sits
            // below the visible content, so holding the offset keeps whatever the
            // user is looking at stationary: a reader at the top stays at the top,
            // and one already at the bottom stays at the bottom (the empty space
            // beneath them simply disappears) without an explicit jump.
            DispatchQueue.main.async {
                finishedWrapper?.resetBuffer()
                DispatchQueue.main.async {
                    guard context.coordinator.lastChatId == currentChatId else {
                        context.coordinator.isCollapsingStreamingBuffer = false
                        // The user switched chats before the collapse ran. Recompute the inset for
                        // the now-visible chat so the temporary streaming inset doesn't linger as
                        // blank space in the reused table view.
                        context.coordinator.updateContentInset()
                        return
                    }
                    UIView.performWithoutAnimation {
                        // A queued message can be dispatched between the stream
                        // ending and this deferred collapse, growing the
                        // datasource before the table has reloaded for it.
                        // begin/endUpdates would assert on the mismatched row
                        // counts; the imminent reload from that count change
                        // re-measures heights anyway, so the collapse pass is
                        // only run while the counts still agree.
                        if tableView.numberOfRows(inSection: 0) == context.coordinator.parent.messages.count {
                            tableView.beginUpdates()
                            tableView.endUpdates()
                        }
                        context.coordinator.isCollapsingStreamingBuffer = false
                        context.coordinator.updateContentInset()
                        tableView.layoutIfNeeded()
                        // Skip the offset restore if a newer scroll action (scroll-to-bottom or
                        // scroll-to-user) cleared the preserved offset while this collapse was
                        // pending, so the more recent scroll intent isn't overridden.
                        if let preserved = context.coordinator.preservedOffsetAfterStreaming {
                            tableView.contentOffset.y = preserved
                        }
                    }
                }
            }
        }

        if context.coordinator.lastScrollToUserTrigger != scrollToUserTrigger {
            context.coordinator.lastScrollToUserTrigger = scrollToUserTrigger
            context.coordinator.shouldScrollToUserMessageAfterLayout = true
            context.coordinator.shouldScrollToBottomAfterLayout = false
            context.coordinator.isUserMessageScrollMode = true
            context.coordinator.preservedOffsetAfterStreaming = nil

            DispatchQueue.main.async {
                context.coordinator.scrollToUserMessage(animated: false)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if context.coordinator.shouldScrollToUserMessageAfterLayout {
                        context.coordinator.scrollToUserMessage(animated: false)
                        context.coordinator.shouldScrollToUserMessageAfterLayout = false

                        withAnimation(.easeIn(duration: 0.2)) {
                            self.tableOpacity = 1.0
                        }
                    }
                }
            }
        }

        if context.coordinator.lastScrollTrigger != scrollTrigger {
            context.coordinator.lastScrollTrigger = scrollTrigger
            context.coordinator.shouldScrollToBottomAfterLayout = true
            context.coordinator.shouldScrollToUserMessageAfterLayout = false
            context.coordinator.isUserMessageScrollMode = false
            context.coordinator.preservedOffsetAfterStreaming = nil

            DispatchQueue.main.async {
                context.coordinator.scrollToBottom(animated: false)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if context.coordinator.shouldScrollToBottomAfterLayout {
                        context.coordinator.scrollToBottom(animated: false)
                        context.coordinator.shouldScrollToBottomAfterLayout = false

                        withAnimation(.easeIn(duration: 0.2)) {
                            self.tableOpacity = 1.0
                        }
                    }
                }
            }
        }

        DispatchQueue.main.async {
            context.coordinator.checkIfAtBottom()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate {
        var parent: MessageTableView
        weak var tableView: UITableView?
        var lastScrollTrigger: UUID?
        var lastScrollToUserTrigger: UUID?
        var lastMessageCount: Int = 0
        var lastUsesStreamingLayout: Bool = false
        var cellReuseIdentifierSuffix: String = ""
        var lastKeyboardHeight: CGFloat = 0
        var lastIsDarkMode: Bool = false
        var lastChatId: String? = nil
        var lastMessageIds: Set<String> = []
        private var isDragging = false
        private var isUpdatingContentInset = false
        var messageWrappers: [String: ObservableMessageWrapper] = [:]
        var shouldScrollToBottomAfterLayout = false
        var shouldScrollToUserMessageAfterLayout = false
        /// Stays true while streaming after user sent a message, adjusting the
        /// bottom inset so the user message can be scrolled to the top of the screen.
        var isUserMessageScrollMode = false
        var preservedOffsetAfterStreaming: CGFloat?
        var isCollapsingStreamingBuffer = false
        /// The message currently rendered with a streaming buffer, updated
        /// synchronously with the datasource (wrapper flags lag one tick).
        var streamingMessageId: String?
        var heightCache: [IndexPath: CGFloat] = [:]
        var messageHeightCache: [String: CGFloat] = [:]
        var contentEstimateCache: [String: CGFloat] = [:]
        var shownMessageIds: Set<String> = []
        var isKeyboardTransitioning = false

        init(_ parent: MessageTableView) {
            self.parent = parent
        }

        func getOrCreateWrapper(for message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, hasRecoveryDraft: Bool, isArchived: Bool, showArchiveSeparator: Bool, messageIndex: Int) -> ObservableMessageWrapper {
            if let existing = messageWrappers[message.id] {
                existing.update(message: message, isDarkMode: isDarkMode, isLastMessage: isLastMessage, isLoading: isLoading, hasRecoveryDraft: hasRecoveryDraft, isArchived: isArchived, showArchiveSeparator: showArchiveSeparator, messageIndex: messageIndex)
                // Never re-animate existing messages
                existing.shouldAnimateAppearance = false
                return existing
            } else {
                let isFirstTimeShown = !shownMessageIds.contains(message.id)
                shownMessageIds.insert(message.id)
                let wrapper = ObservableMessageWrapper(message: message, isDarkMode: isDarkMode, isLastMessage: isLastMessage, isLoading: isLoading, hasRecoveryDraft: hasRecoveryDraft, isArchived: isArchived, showArchiveSeparator: showArchiveSeparator, shouldAnimateAppearance: isFirstTimeShown, messageIndex: messageIndex)
                messageWrappers[message.id] = wrapper
                return wrapper
            }
        }

        @objc func handleBackgroundTap() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Only treat taps on non-interactive areas as background taps. Taps on buttons,
            // editable text fields, and the inline message editor must not dismiss the keyboard.
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UITextField {
                    return false
                }
                if let textView = current as? UITextView, textView.isEditable {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            return 1
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            if parent.messages.isEmpty {
                return 1
            }
            return parent.messages.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cellIdentifier = (parent.messages.isEmpty ? "WelcomeCell" : "MessageCell") + cellReuseIdentifierSuffix

            let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier) ?? UITableViewCell(style: .default, reuseIdentifier: cellIdentifier)
            cell.selectionStyle = .none
            cell.backgroundColor = .clear

            if parent.messages.isEmpty {
                cell.contentConfiguration = UIHostingConfiguration {
                    if let authManager = parent.viewModel.authManager {
                        WelcomeView(
                            isDarkMode: parent.isDarkMode,
                            authManager: authManager,
                            onRequestSignIn: parent.onRequestSignIn
                        )
                        .padding(.vertical, 16)
                        .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 0)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                        .markdownStyleHost(isDarkMode: parent.isDarkMode)
                    }
                }
                .minSize(width: 0, height: 0)
                .margins(.all, 0)
                .background(.clear)
                cell.boundContentToken = "welcome"
            } else {
                let message = parent.messages[indexPath.row]
                let isLastMessage = indexPath.row == parent.messages.count - 1
                let isArchived = indexPath.row < parent.archivedMessagesStartIndex
                let showArchiveSeparator = indexPath.row == parent.archivedMessagesStartIndex && parent.archivedMessagesStartIndex > 0

                let wrapper = getOrCreateWrapper(
                    for: message,
                    isDarkMode: parent.isDarkMode,
                    isLastMessage: isLastMessage,
                    isLoading: parent.isLoading && isLastMessage,
                    hasRecoveryDraft: parent.hasRecoveryDraft(message),
                    isArchived: isArchived,
                    showArchiveSeparator: showArchiveSeparator,
                    messageIndex: indexPath.row
                )

                // Only rebuild the hosting configuration when the cell is now
                // bound to a different message. Reassigning the configuration
                // for the same wrapper tears down the SwiftUI subgraph and
                // can deallocate AG attributes that an in-flight context
                // menu animation is still tracking - the cause of the
                // ContextMenuResponder.startTrackingUpdates EXC_BAD_ACCESS
                // we see when the table reloads during streaming.
                if cell.boundContentToken != message.id {
                    cell.contentConfiguration = UIHostingConfiguration {
                        ObservableMessageCell(wrapper: wrapper, viewModel: parent.viewModel, coordinator: self)
                    }
                    .minSize(width: 0, height: 0)
                    .margins(.all, 0)
                    .background(.clear)
                    cell.boundContentToken = message.id
                }
            }

            return cell
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            if let cachedHeight = heightCache[indexPath] {
                return cachedHeight
            }
            // Fall back to message-ID-based cache (survives reloadData)
            if indexPath.row < parent.messages.count {
                let message = parent.messages[indexPath.row]
                if let cachedHeight = messageHeightCache[message.id] {
                    return cachedHeight
                }
                // No measured height yet: approximate from the message content
                // so the table's contentSize is close to correct before the
                // row is displayed. A flat guess here would make contentSize
                // lurch as each taller-than-guessed row is revealed, which is
                // what made scrolling up snap back to the bottom.
                return contentBasedEstimate(for: message, width: tableView.bounds.width)
            }
            return Constants.HeightEstimation.fallbackHeight
        }

        /// Approximate row height for a message that has never been measured,
        /// derived from its text length, reasoning pill, and attachments.
        private func contentBasedEstimate(for message: Message, width: CGFloat) -> CGFloat {
            if let cached = contentEstimateCache[message.id] {
                return cached
            }

            let contentWidth = max(120, width - Constants.HeightEstimation.horizontalChrome)
            let charsPerLine = max(1, contentWidth / Constants.HeightEstimation.averageCharacterWidth)

            let wrappedLines = (CGFloat(message.content.count) / charsPerLine).rounded(.up)
            let explicitLines = CGFloat(message.content.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            })
            let lines = max(1, max(wrappedLines, explicitLines))

            var height = lines * Constants.HeightEstimation.lineHeight + Constants.HeightEstimation.verticalChrome
            if let thoughts = message.thoughts, !thoughts.isEmpty {
                height += Constants.HeightEstimation.thoughtsHeight
            }
            height += CGFloat(message.attachments.count) * Constants.HeightEstimation.attachmentHeight

            let result = max(height, Constants.HeightEstimation.minimumHeight)
            contentEstimateCache[message.id] = result
            return result
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            // Skip the streaming last row: while it is loading its frame is
            // inflated by the streaming buffer. Caching that value would poison
            // future estimates after the buffer collapses.
            let isStreamingLastRow = isStreamingRow(at: indexPath)
            let height = cell.frame.size.height
            if height > 0 && !isStreamingLastRow {
                heightCache[indexPath] = height
                if indexPath.row < parent.messages.count {
                    messageHeightCache[parent.messages[indexPath.row].id] = height
                }
            }

            if shouldScrollToBottomAfterLayout {
                let numberOfRows = tableView.numberOfRows(inSection: 0)
                if indexPath.row == numberOfRows - 1 {
                    DispatchQueue.main.async {
                        self.scrollToBottom(animated: false)
                        self.shouldScrollToBottomAfterLayout = false

                        withAnimation(.easeIn(duration: 0.2)) {
                            self.parent.tableOpacity = 1.0
                        }
                    }
                }
            }

            if shouldScrollToUserMessageAfterLayout {
                let numberOfRows = tableView.numberOfRows(inSection: 0)
                if indexPath.row == numberOfRows - 1 {
                    DispatchQueue.main.async {
                        self.scrollToUserMessage(animated: false)
                        self.shouldScrollToUserMessageAfterLayout = false

                        withAnimation(.easeIn(duration: 0.2)) {
                            self.parent.tableOpacity = 1.0
                        }
                    }
                }
            }
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            // Cache measured heights for future estimates only. Rows still use
            // automatic sizing so late SwiftUI layout cannot overflow a pinned
            // cell height.
            guard indexPath.row < parent.messages.count else { return }
            if isStreamingRow(at: indexPath) { return }
            let height = cell.frame.size.height
            guard height > 0 else { return }
            messageHeightCache[parent.messages[indexPath.row].id] = height
            heightCache[indexPath] = height
        }

        private func isStreamingRow(at indexPath: IndexPath) -> Bool {
            guard indexPath.row < parent.messages.count else { return false }
            let message = parent.messages[indexPath.row]
            // Wrapper flags lag the datasource by a runloop tick, so a message
            // that just stopped being the streaming last row (queued dispatch
            // appended rows behind it) can still render its buffer this tick.
            // Trust the wrapper's claim wherever the row sits so that inflated
            // frame never enters the height caches.
            if parent.hasRecoveryDraft(message) {
                return true
            }
            if let wrapper = messageWrappers[message.id], wrapper.isLoading, wrapper.isLastMessage {
                return true
            }
            guard indexPath.row == parent.messages.count - 1 else { return false }
            return parent.usesStreamingLayout
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateContentInset()
            checkIfAtBottom()
        }

        func updateContentInset() {
            guard !isUpdatingContentInset else { return }
            guard !isCollapsingStreamingBuffer else { return }
            guard let tableView = tableView else { return }
            isUpdatingContentInset = true
            defer { isUpdatingContentInset = false }

            let targetInset: CGFloat

            if parent.usesStreamingLayout, let lastMessage = parent.messages.last,
               let wrapper = messageWrappers[lastMessage.id], wrapper.actualContentHeight > 0 {

                let screenHeight = UIScreen.main.bounds.height
                let bufferHeight = screenHeight * wrapper.bufferMultiplier
                let unusedBuffer = bufferHeight - wrapper.actualContentHeight
                let streamingInset = -max(0, unusedBuffer)

                if isUserMessageScrollMode {
                    let userMessageInset = insetForUserMessageAtTop(tableView)
                    targetInset = max(streamingInset, userMessageInset)
                } else {
                    targetInset = streamingInset
                }
            } else if parent.usesStreamingLayout && isUserMessageScrollMode {
                targetInset = insetForUserMessageAtTop(tableView)
            } else if isUserMessageScrollMode {
                // Streaming has ended but the user is still reading with their
                // message near the top; keep enough bottom inset to hold that
                // position instead of snapping to the bottom of the response.
                targetInset = max(0, insetForUserMessageAtTop(tableView), insetForPreservedOffset(tableView))
            } else if preservedOffsetAfterStreaming != nil {
                targetInset = max(0, insetForPreservedOffset(tableView))
            } else {
                targetInset = 0
            }

            if tableView.contentInset.bottom != targetInset {
                UIView.performWithoutAnimation {
                    tableView.contentInset.bottom = targetInset
                    tableView.verticalScrollIndicatorInsets.bottom = targetInset
                }
            }
        }

        /// Returns the minimum bottom inset that allows the user message row
        /// (second-to-last) to be scrolled to the top of the visible area.
        private func insetForUserMessageAtTop(_ tableView: UITableView) -> CGFloat {
            let numberOfRows = tableView.numberOfRows(inSection: 0)
            guard numberOfRows >= 2 else { return 0 }
            let userMessageIndexPath = IndexPath(row: numberOfRows - 2, section: 0)
            let userMessageY = tableView.rectForRow(at: userMessageIndexPath).origin.y
            return userMessageY + tableView.bounds.height - tableView.contentSize.height
        }

        private func insetForPreservedOffset(_ tableView: UITableView) -> CGFloat {
            guard let preservedOffsetAfterStreaming else { return 0 }
            return preservedOffsetAfterStreaming + tableView.bounds.height - tableView.contentSize.height
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isDragging = true
            parent.userHasScrolled = true
            parent.viewModel.isScrollInteractionActive = true
            shouldScrollToBottomAfterLayout = false
            shouldScrollToUserMessageAfterLayout = false

            UIView.animate(withDuration: 0.3) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
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
            guard let tableView = tableView else { return }
            guard !parent.messages.isEmpty else { return }

            updateContentInset()

            let numberOfRows = tableView.numberOfRows(inSection: 0)
            guard numberOfRows > 0 else { return }
            guard numberOfRows == parent.messages.count || parent.messages.isEmpty else { return }

            let lastIndexPath = IndexPath(row: numberOfRows - 1, section: 0)
            tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: animated)
        }

        /// Scrolls so the user's message sits at the top of the visible area,
        /// with the assistant response streaming in below it.
        func scrollToUserMessage(animated: Bool) {
            guard let tableView = tableView else { return }

            let numberOfRows = tableView.numberOfRows(inSection: 0)
            guard numberOfRows >= 2 else {
                scrollToBottom(animated: animated)
                return
            }
            guard numberOfRows == parent.messages.count else { return }

            updateContentInset()

            let userMessageIndexPath = IndexPath(row: numberOfRows - 2, section: 0)
            tableView.scrollToRow(at: userMessageIndexPath, at: .top, animated: animated)
        }

        /// VoiceOver rotor that lets users flick up/down to jump between
        /// whole messages instead of stepping element-by-element from the top.
        func makeMessagesRotor() -> UIAccessibilityCustomRotor {
            UIAccessibilityCustomRotor(name: Constants.Accessibility.messagesRotorName) { [weak self] predicate in
                guard let self = self, let tableView = self.tableView else { return nil }
                let rowCount = tableView.numberOfRows(inSection: 0)
                guard rowCount > 0, !self.parent.messages.isEmpty else { return nil }

                let forward = predicate.searchDirection == .next
                let targetRow: Int
                if let currentRow = self.rowForRotorElement(predicate.currentItem.targetElement, in: tableView) {
                    targetRow = forward ? currentRow + 1 : currentRow - 1
                } else {
                    targetRow = forward ? 0 : rowCount - 1
                }

                guard targetRow >= 0, targetRow < rowCount else { return nil }

                let indexPath = IndexPath(row: targetRow, section: 0)
                tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
                tableView.layoutIfNeeded()
                guard let cell = tableView.cellForRow(at: indexPath) else { return nil }
                return UIAccessibilityCustomRotorItemResult(targetElement: cell, targetRange: nil)
            }
        }

        /// Resolves the table row that owns the currently focused accessibility
        /// element by mapping its on-screen frame back into table coordinates.
        private func rowForRotorElement(_ element: Any?, in tableView: UITableView) -> Int? {
            guard let object = element as? NSObject,
                  let window = tableView.window else { return nil }

            let screenFrame = object.accessibilityFrame
            guard !screenFrame.isNull, !screenFrame.isEmpty else { return nil }

            let windowFrame = window.convert(screenFrame, from: window.screen.coordinateSpace)
            let tableFrame = tableView.convert(windowFrame, from: window)
            let center = CGPoint(x: tableFrame.midX, y: tableFrame.midY)
            return tableView.indexPathForRow(at: center)?.row
        }

        func checkIfAtBottom() {
            guard let tableView = tableView else { return }
            guard tableView.window != nil else { return }

            let contentHeight = tableView.contentSize.height
            let bottomInset = tableView.contentInset.bottom
            let viewHeight = tableView.bounds.height
            let currentOffset = tableView.contentOffset.y

            let maxOffset = contentHeight - viewHeight + bottomInset
            let distanceFromBottom = maxOffset - currentOffset

            let slack: CGFloat = 150
            let isVisible = distanceFromBottom <= slack

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

class ObservableMessageWrapper: ObservableObject {
    @Published var message: Message
    @Published var isDarkMode: Bool
    @Published var isLastMessage: Bool
    @Published var isLoading: Bool
    @Published var hasRecoveryDraft: Bool
    @Published var isArchived: Bool
    @Published var showArchiveSeparator: Bool
    var shouldAnimateAppearance: Bool = false
    @Published var messageIndex: Int
    var bufferMultiplier: CGFloat = Constants.StreamingBuffer.initialMultiplier
    var actualContentHeight: CGFloat = 0
    var cachedHeight: CGFloat?
    var cachedHeightKey: Int?

    init(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, hasRecoveryDraft: Bool = false, isArchived: Bool, showArchiveSeparator: Bool, shouldAnimateAppearance: Bool = true, messageIndex: Int = 0) {
        self.message = message
        self.isDarkMode = isDarkMode
        self.isLastMessage = isLastMessage
        self.isLoading = isLoading
        self.hasRecoveryDraft = hasRecoveryDraft
        self.isArchived = isArchived
        self.showArchiveSeparator = showArchiveSeparator
        self.shouldAnimateAppearance = shouldAnimateAppearance
        self.messageIndex = messageIndex
    }

    func update(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, hasRecoveryDraft: Bool, isArchived: Bool, showArchiveSeparator: Bool, messageIndex: Int) {
        let contentChanged = self.message.content != message.content ||
                            self.message.thoughts != message.thoughts ||
                            self.message.contentChunks != message.contentChunks ||
                            self.message.thinkingChunks != message.thinkingChunks ||
                            self.message.isThinking != message.isThinking ||
                            self.message.isCollapsed != message.isCollapsed ||
                            self.message.generationTimeSeconds != message.generationTimeSeconds ||
                            self.message.streamError != message.streamError ||
                            self.message.webSearchState != message.webSearchState ||
                            self.message.urlFetches != message.urlFetches ||
                            self.message.segments != message.segments ||
                            self.message.webSearches != message.webSearches ||
                            self.message.toolCalls != message.toolCalls ||
                            self.message.timeline != message.timeline ||
                            self.message.annotations != message.annotations ||
                            self.message.webSearchBeforeThinking != message.webSearchBeforeThinking ||
                            self.isDarkMode != isDarkMode

        let metadataChanged = self.isLastMessage != isLastMessage ||
                              self.isLoading != isLoading ||
                              self.hasRecoveryDraft != hasRecoveryDraft ||
                              self.isArchived != isArchived ||
                              self.showArchiveSeparator != showArchiveSeparator ||
                              self.messageIndex != messageIndex

        if !contentChanged && !metadataChanged {
            return
        }

        if contentChanged {
            cachedHeight = nil
            cachedHeightKey = nil
        }

        // Defer @Published property updates to the next run loop tick.
        // UIHostingConfiguration requires the objectWillChange notification
        // to arrive on a separate run loop iteration to trigger a re-render.
        DispatchQueue.main.async {
            self.message = message
            self.isDarkMode = isDarkMode
            self.isLastMessage = isLastMessage
            self.isLoading = isLoading
            self.hasRecoveryDraft = hasRecoveryDraft
            self.isArchived = isArchived
            self.showArchiveSeparator = showArchiveSeparator
            self.messageIndex = messageIndex
        }
    }

    /// Checks whether the streaming buffer needs to grow and extends it if so.
    /// Returns true if the buffer was extended.
    @discardableResult
    func extendBufferIfNeeded(screenHeight: CGFloat) -> Bool {
        let currentBufferHeight = screenHeight * bufferMultiplier
        let threshold = currentBufferHeight * Constants.StreamingBuffer.extensionThresholdRatio
        let needsExtension = actualContentHeight > threshold
            && bufferMultiplier < Constants.StreamingBuffer.maxMultiplier

        if needsExtension {
            bufferMultiplier += Constants.StreamingBuffer.multiplierIncrement
        }
        return needsExtension
    }

    func resetBuffer() {
        bufferMultiplier = Constants.StreamingBuffer.initialMultiplier
        actualContentHeight = 0
    }

    func getCacheKey() -> Int {
        message.content.hashValue ^
        (message.thoughts?.hashValue ?? 0) ^
        (message.contentChunks.hashValue) ^
        (message.thinkingChunks.hashValue) ^
        isDarkMode.hashValue
    }
}

struct ObservableMessageCell: View {
    @ObservedObject var wrapper: ObservableMessageWrapper
    @ObservedObject var viewModel: ChatViewModel
    weak var coordinator: MessageTableView.Coordinator?
    @State private var hasAppeared = false

    private var bufferHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        return min(
            screenHeight * wrapper.bufferMultiplier,
            Constants.StreamingBuffer.maxCellHeight
        )
    }

    /// Wrapper flags update a runloop tick behind the datasource, so they can
    /// still mark a finished message as the streaming last row while a reload
    /// is measuring cells (queued dispatch landing at stream end). Requiring
    /// the coordinator's synchronous id keeps the buffer off such rows.
    private var showsStreamingBuffer: Bool {
        (wrapper.isLoading || wrapper.hasRecoveryDraft) && wrapper.isLastMessage
            && coordinator?.streamingMessageId == wrapper.message.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if wrapper.showArchiveSeparator {
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Older messages above are archived")
            }

            ZStack(alignment: .topLeading) {
                if showsStreamingBuffer {
                    Color.clear
                        .frame(height: bufferHeight)
                }

                MessageView(
                    message: wrapper.message,
                    isDarkMode: wrapper.isDarkMode,
                    isLastMessage: wrapper.isLastMessage,
                    isLoading: wrapper.isLoading,
                    hasRecoveryDraft: wrapper.hasRecoveryDraft,
                    messageIndex: wrapper.messageIndex
                )
                .environmentObject(viewModel)
                .markdownStyleHost(isDarkMode: wrapper.isDarkMode)
                .opacity(wrapper.isArchived ? 0.6 : 1.0)
                .padding(.vertical, 8)
                .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 8)
                .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                    view.frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                }
                .if(showsStreamingBuffer) { view in
                    view.background(
                        GeometryReader { geometry in
                            Color.clear
                                // Report the initial height too: when the user
                                // switches back to a chat that is mid-stream its
                                // wrapper is recreated, and without this the
                                // content height stays 0 until the next token,
                                // so the unused buffer cannot be inset away and
                                // scroll-to-bottom lands in blank space.
                                .onAppear {
                                    wrapper.actualContentHeight = geometry.size.height
                                }
                                .onChange(of: geometry.size.height) { _, newHeight in
                                    wrapper.actualContentHeight = newHeight
                                }
                        }
                    )
                }
            }
        }
        .opacity(wrapper.shouldAnimateAppearance && !hasAppeared ? 0 : 1)
        .onAppear {
            if wrapper.shouldAnimateAppearance && !hasAppeared {
                withAnimation(.easeIn(duration: 0.2)) {
                    hasAppeared = true
                }
            } else {
                hasAppeared = true
            }
        }
    }
}

/// Applies the Textual styles every markdown view in a message cell needs,
/// once at the cell host. Doing this here means the eleven environment
/// writes that `structuredTextStyle(.gitHub)` expands into are paid one
/// time per cell instead of once per `LaTeXMarkdownView` / `SegmentView`
/// inside the cell, which is what was driving the long `compareLists` /
/// `EnvironmentBox.update` hangs in production.
struct MarkdownStyleHost: ViewModifier {
    let isDarkMode: Bool

    func body(content: Content) -> some View {
        content
            .textual.structuredTextStyle(.gitHub)
            .environment(\.colorScheme, isDarkMode ? .dark : .light)
    }
}

extension View {
    func markdownStyleHost(isDarkMode: Bool) -> some View {
        modifier(MarkdownStyleHost(isDarkMode: isDarkMode))
    }
}

extension UITableViewCell {
    private static var boundContentTokenKey: UInt8 = 0

    /// Identifier of the content currently hosted by this cell ("welcome" or
    /// a message id). Used to skip a `contentConfiguration` reassignment when
    /// the cell is being dequeued for the same logical content it already
    /// hosts.
    fileprivate var boundContentToken: String? {
        get {
            objc_getAssociatedObject(self, &Self.boundContentTokenKey) as? String
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.boundContentTokenKey,
                newValue,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
        }
    }
}

