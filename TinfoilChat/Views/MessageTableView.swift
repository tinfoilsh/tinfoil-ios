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

    private var messages: [Message] {
        viewModel.messages
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
        let currentMessageIds = Set(viewModel.messages.map { $0.id })
        let isIdConversion = chatIdChanged && !currentMessageIds.isEmpty &&
            currentMessageIds == context.coordinator.lastMessageIds

        if chatIdChanged {
            context.coordinator.lastChatId = currentChatId

            if !isIdConversion {
                context.coordinator.messageWrappers.removeAll()
                context.coordinator.shownMessageIds.removeAll()
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
        } else if isLoading && !messages.isEmpty {
            // During streaming, update the last message wrapper directly
            if let lastMessage = messages.last,
               let wrapper = context.coordinator.messageWrappers[lastMessage.id] {

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
                    guard let currentMessage = coordinator.parent.messages.last else { return }

                    wrapper.update(
                        message: currentMessage,
                        isDarkMode: coordinator.parent.isDarkMode,
                        isLastMessage: true,
                        isLoading: coordinator.parent.isLoading,
                        isArchived: isArchived,
                        showArchiveSeparator: showArchiveSeparator,
                        messageIndex: coordinator.parent.messages.count - 1
                    )

                    if needsBufferExtension && !coordinator.isKeyboardTransitioning {
                        tableView.beginUpdates()
                        tableView.endUpdates()
                    }
                }
            }
        }

        let isLoadingChanged = context.coordinator.lastIsLoading != isLoading
        context.coordinator.lastIsLoading = isLoading

        if isLoadingChanged && !isLoading {
            // Streaming just ended - update the last message wrapper to reflect final state (including any errors)
            if let lastMessage = messages.last,
               let wrapper = context.coordinator.messageWrappers[lastMessage.id] {
                let isArchived = messages.count - 1 < archivedMessagesStartIndex
                let showArchiveSeparator = messages.count - 1 == archivedMessagesStartIndex && archivedMessagesStartIndex > 0
                wrapper.update(
                    message: lastMessage,
                    isDarkMode: isDarkMode,
                    isLastMessage: true,
                    isLoading: false,
                    isArchived: isArchived,
                    showArchiveSeparator: showArchiveSeparator,
                    messageIndex: messages.count - 1
                )

                DispatchQueue.main.async {
                    wrapper.resetBuffer()
                }
            }

            // Capture the user's intent before any layout change. Follow down to
            // the end only when the user was passively watching from the bottom.
            // When their sent message is pinned to the top (the normal send
            // flow), keep that reading position instead of snapping to the
            // bottom of the finished response.
            let wasFollowing = !userHasScrolled && !context.coordinator.isUserMessageScrollMode

            DispatchQueue.main.async {
                UIView.performWithoutAnimation {
                    // Temporarily inflate the bottom inset so the collapsing
                    // streaming buffer cannot clamp the offset and snap the view
                    // to the bottom before the final inset is settled below.
                    let currentOffset = tableView.contentOffset.y
                    tableView.contentInset.bottom = tableView.bounds.height
                    tableView.layoutIfNeeded()
                    tableView.contentOffset.y = currentOffset
                }

                DispatchQueue.main.async {
                    if wasFollowing {
                        context.coordinator.isUserMessageScrollMode = false
                        context.coordinator.scrollToBottom(animated: false)
                    } else {
                        UIView.performWithoutAnimation {
                            let currentOffset = tableView.contentOffset.y
                            context.coordinator.updateContentInset()
                            tableView.layoutIfNeeded()
                            tableView.contentOffset.y = currentOffset
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

    class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource {
        var parent: MessageTableView
        weak var tableView: UITableView?
        var lastScrollTrigger: UUID?
        var lastScrollToUserTrigger: UUID?
        var lastMessageCount: Int = 0
        var lastIsLoading: Bool = false
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
        var heightCache: [IndexPath: CGFloat] = [:]
        var messageHeightCache: [String: CGFloat] = [:]
        var contentEstimateCache: [String: CGFloat] = [:]
        var shownMessageIds: Set<String> = []
        var isKeyboardTransitioning = false

        init(_ parent: MessageTableView) {
            self.parent = parent
        }

        func getOrCreateWrapper(for message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool, messageIndex: Int) -> ObservableMessageWrapper {
            if let existing = messageWrappers[message.id] {
                existing.update(message: message, isDarkMode: isDarkMode, isLastMessage: isLastMessage, isLoading: isLoading, isArchived: isArchived, showArchiveSeparator: showArchiveSeparator, messageIndex: messageIndex)
                // Never re-animate existing messages
                existing.shouldAnimateAppearance = false
                return existing
            } else {
                let isFirstTimeShown = !shownMessageIds.contains(message.id)
                shownMessageIds.insert(message.id)
                let wrapper = ObservableMessageWrapper(message: message, isDarkMode: isDarkMode, isLastMessage: isLastMessage, isLoading: isLoading, isArchived: isArchived, showArchiveSeparator: showArchiveSeparator, shouldAnimateAppearance: isFirstTimeShown, messageIndex: messageIndex)
                messageWrappers[message.id] = wrapper
                return wrapper
            }
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
            // inflated by the streaming buffer (many screens tall). Caching that
            // value would make heightForRowAt later pin the finished row to the
            // buffer height - a giant blank cell the user scrolls through without
            // ever seeing the response. didEndDisplaying guards this the same way.
            let isStreamingLastRow = parent.isLoading && indexPath.row == parent.messages.count - 1
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
            // Cache the settled height once a row leaves the screen. By this
            // point any asynchronously rendered content (LaTeX, generative-UI
            // cards) has laid out, so this is the most accurate height to pin
            // the row to on its next appearance.
            guard indexPath.row < parent.messages.count else { return }
            let isLastMessage = indexPath.row == parent.messages.count - 1
            if parent.isLoading && isLastMessage { return }
            let height = cell.frame.size.height
            guard height > 0 else { return }
            messageHeightCache[parent.messages[indexPath.row].id] = height
            heightCache[indexPath] = height
        }

        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            // While the user is actively scrolling, pin already-measured rows to
            // their cached height. Re-measuring self-sizing rows mid-scroll makes
            // contentSize oscillate (a row reports a slightly different height
            // each time it re-enters), and UIKit answers every change by shifting
            // contentOffset - the feedback loop that snaps the view back and makes
            // scrolling up impossible. When stationary, rows resize normally so
            // reasoning toggles and late-rendering content settle correctly.
            guard tableView.isDragging || tableView.isDecelerating else {
                return UITableView.automaticDimension
            }
            guard indexPath.row < parent.messages.count else {
                return UITableView.automaticDimension
            }
            let isLastMessage = indexPath.row == parent.messages.count - 1
            if parent.isLoading && isLastMessage {
                return UITableView.automaticDimension
            }
            let message = parent.messages[indexPath.row]
            // Messages with generative-UI widgets render asynchronously and can
            // grow after their height was first cached. Pinning them to that
            // stale height makes the taller content overflow onto adjacent rows
            // (the table has clipsToBounds off), which stacks cells on top of
            // each other. Always let these rows self-size.
            if !message.toolCalls.isEmpty {
                return UITableView.automaticDimension
            }
            if let cached = messageHeightCache[message.id] {
                return cached
            }
            return UITableView.automaticDimension
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateContentInset()
            checkIfAtBottom()
        }

        func updateContentInset() {
            guard !isUpdatingContentInset else { return }
            guard let tableView = tableView else { return }
            isUpdatingContentInset = true
            defer { isUpdatingContentInset = false }

            let targetInset: CGFloat

            if parent.isLoading, let lastMessage = parent.messages.last,
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
            } else if parent.isLoading && isUserMessageScrollMode {
                targetInset = insetForUserMessageAtTop(tableView)
            } else if isUserMessageScrollMode {
                // Streaming has ended but the user is still reading with their
                // message near the top; keep enough bottom inset to hold that
                // position instead of snapping to the bottom of the response.
                targetInset = max(0, insetForUserMessageAtTop(tableView))
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
    @Published var isArchived: Bool
    @Published var showArchiveSeparator: Bool
    @Published var shouldAnimateAppearance: Bool = false
    @Published var messageIndex: Int
    var bufferMultiplier: CGFloat = Constants.StreamingBuffer.initialMultiplier
    var actualContentHeight: CGFloat = 0
    var cachedHeight: CGFloat?
    var cachedHeightKey: Int?

    init(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool, shouldAnimateAppearance: Bool = true, messageIndex: Int = 0) {
        self.message = message
        self.isDarkMode = isDarkMode
        self.isLastMessage = isLastMessage
        self.isLoading = isLoading
        self.isArchived = isArchived
        self.showArchiveSeparator = showArchiveSeparator
        self.shouldAnimateAppearance = shouldAnimateAppearance
        self.messageIndex = messageIndex
    }

    func update(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool, messageIndex: Int) {
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
                            self.isDarkMode != isDarkMode

        let metadataChanged = self.isLastMessage != isLastMessage ||
                              self.isLoading != isLoading ||
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
                if wrapper.isLoading && wrapper.isLastMessage {
                    Color.clear
                        .frame(height: bufferHeight)
                }

                MessageView(
                    message: wrapper.message,
                    isDarkMode: wrapper.isDarkMode,
                    isLastMessage: wrapper.isLastMessage,
                    isLoading: wrapper.isLoading,
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
                .if(wrapper.isLoading && wrapper.isLastMessage) { view in
                    view.background(
                        GeometryReader { geometry in
                            Color.clear
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

