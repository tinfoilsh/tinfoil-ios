//
//  MessageTableView.swift
//  TinfoilChat
//
//  UITableView-based message list with cell reuse
//

import SwiftUI

struct MessageTableView: UIViewRepresentable {
    let messages: [Message]
    let archivedMessagesStartIndex: Int
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Binding var isAtBottom: Bool
    @Binding var userHasScrolled: Bool
    let scrollTrigger: UUID
    @Binding var tableOpacity: Double
    let keyboardHeight: CGFloat

    // Track streaming content to trigger updates
    private var streamingContentHash: Int {
        guard !messages.isEmpty, isLoading else { return 0 }
        let lastMessage = messages[messages.count - 1]
        return lastMessage.content.count ^ (lastMessage.thoughts?.count ?? 0) ^ (lastMessage.isThinking ? 1 : 0)
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.keyboardDismissMode = .onDrag
        tableView.allowsSelection = false
        tableView.estimatedRowHeight = 100
        tableView.rowHeight = UITableView.automaticDimension
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.clipsToBounds = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        context.coordinator.tableView = tableView

        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.parent = self

        let keyboardHeightChanged = context.coordinator.lastKeyboardHeight != keyboardHeight
        if keyboardHeightChanged {
            let wasAtBottom = context.coordinator.parent.isAtBottom
            context.coordinator.lastKeyboardHeight = keyboardHeight

            if wasAtBottom && keyboardHeight > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    context.coordinator.scrollToBottom(animated: true)
                }
            }
        }

        let messageCountChanged = context.coordinator.lastMessageCount != messages.count
        let streamingHashChanged = context.coordinator.lastStreamingHash != streamingContentHash

        if messageCountChanged {
            context.coordinator.lastMessageCount = messages.count
            context.coordinator.lastStreamingHash = streamingContentHash
            context.coordinator.heightCache.removeAll()
            tableView.reloadData()
        } else if streamingHashChanged && !messages.isEmpty {
            context.coordinator.lastStreamingHash = streamingContentHash

            let lastMessage = messages[messages.count - 1]
            if let wrapper = context.coordinator.messageWrappers[lastMessage.id] {
                let isLastMessage = true
                let isArchived = messages.count - 1 < archivedMessagesStartIndex
                let showArchiveSeparator = messages.count - 1 == archivedMessagesStartIndex && archivedMessagesStartIndex > 0

                let screenHeight = UIScreen.main.bounds.height
                let currentBufferHeight = screenHeight * wrapper.bufferMultiplier
                let threshold = currentBufferHeight * 0.8

                let needsBufferExtension = wrapper.actualContentHeight > threshold && wrapper.actualContentHeight > wrapper.lastExtendedAtHeight + 50

                DispatchQueue.main.async {
                    wrapper.message = lastMessage
                    wrapper.isDarkMode = isDarkMode
                    wrapper.isLastMessage = isLastMessage
                    wrapper.isLoading = isLoading
                    wrapper.isArchived = isArchived
                    wrapper.showArchiveSeparator = showArchiveSeparator

                    if needsBufferExtension {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)

                        let currentOffset = tableView.contentOffset.y

                        wrapper.bufferMultiplier += 1.0
                        wrapper.lastExtendedAtHeight = wrapper.actualContentHeight

                        tableView.layoutIfNeeded()

                        tableView.contentOffset.y = currentOffset

                        CATransaction.commit()
                    }
                }
            }
        }

        let isLoadingChanged = context.coordinator.lastIsLoading != isLoading
        context.coordinator.lastIsLoading = isLoading

        if isLoadingChanged && !isLoading {
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                let currentOffset = tableView.contentOffset.y
                tableView.layoutIfNeeded()
                tableView.contentOffset.y = currentOffset

                CATransaction.commit()
            }
        }

        if context.coordinator.lastScrollTrigger != scrollTrigger {
            context.coordinator.lastScrollTrigger = scrollTrigger
            context.coordinator.shouldScrollToBottomAfterLayout = true

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
        var lastMessageCount: Int = 0
        var lastIsLoading: Bool = false
        var lastStreamingHash: Int = 0
        var lastKeyboardHeight: CGFloat = 0
        private var isDragging = false
        var messageWrappers: [String: ObservableMessageWrapper] = [:]
        var shouldScrollToBottomAfterLayout = false
        var heightCache: [IndexPath: CGFloat] = [:]

        init(_ parent: MessageTableView) {
            self.parent = parent
        }

        func getOrCreateWrapper(for message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool) -> ObservableMessageWrapper {
            if let existing = messageWrappers[message.id] {
                existing.update(message: message, isDarkMode: isDarkMode, isLastMessage: isLastMessage, isLoading: isLoading, isArchived: isArchived, showArchiveSeparator: showArchiveSeparator)
                return existing
            } else {
                let wrapper = ObservableMessageWrapper(message: message, isDarkMode: isDarkMode, isLastMessage: isLastMessage, isLoading: isLoading, isArchived: isArchived, showArchiveSeparator: showArchiveSeparator)
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
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
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
                    }
                }
                .minSize(width: 0, height: 0)
                .margins(.all, 0)
                .background(.clear)
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
                    showArchiveSeparator: showArchiveSeparator
                )

                cell.contentConfiguration = UIHostingConfiguration {
                    ObservableMessageCell(wrapper: wrapper, viewModel: parent.viewModel, coordinator: self)
                }
                .minSize(width: 0, height: 0)
                .margins(.all, 0)
                .background(.clear)
            }

            return cell
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            if let cachedHeight = heightCache[indexPath] {
                return cachedHeight
            }
            return 100
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            let height = cell.frame.size.height
            if height > 0 {
                heightCache[indexPath] = height
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
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateContentInset()
            checkIfAtBottom()
        }

        func updateContentInset() {
            guard let tableView = tableView else { return }

            let targetInset: CGFloat

            if parent.isLoading, let lastMessage = parent.messages.last,
               let wrapper = messageWrappers[lastMessage.id], wrapper.actualContentHeight > 0 {

                let screenHeight = UIScreen.main.bounds.height
                let bufferHeight = screenHeight * wrapper.bufferMultiplier
                let unusedBuffer = bufferHeight - wrapper.actualContentHeight

                targetInset = -max(0, unusedBuffer)
            } else {
                targetInset = 0
            }

            if tableView.contentInset.bottom != targetInset {
                tableView.contentInset.bottom = targetInset
                tableView.scrollIndicatorInsets.bottom = targetInset
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isDragging = true
            parent.userHasScrolled = true
            parent.viewModel.isScrollInteractionActive = true
            shouldScrollToBottomAfterLayout = false

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

            let lastIndexPath = IndexPath(row: numberOfRows - 1, section: 0)
            tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: animated)
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
    var actualContentHeight: CGFloat = 0
    var bufferMultiplier: CGFloat = 1.0
    var lastExtendedAtHeight: CGFloat = 0
    var lastReportedHeight: CGFloat = 0
    var cachedHeight: CGFloat?
    var cachedHeightKey: Int?

    init(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool) {
        self.message = message
        self.isDarkMode = isDarkMode
        self.isLastMessage = isLastMessage
        self.isLoading = isLoading
        self.isArchived = isArchived
        self.showArchiveSeparator = showArchiveSeparator
    }

    func update(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool) {
        let contentChanged = self.message.content != message.content ||
                            self.message.thoughts != message.thoughts ||
                            self.message.contentChunks != message.contentChunks ||
                            self.isDarkMode != isDarkMode

        if contentChanged {
            cachedHeight = nil
            cachedHeightKey = nil
        }

        self.message = message
        self.isDarkMode = isDarkMode
        self.isLastMessage = isLastMessage
        self.isLoading = isLoading
        self.isArchived = isArchived
        self.showArchiveSeparator = showArchiveSeparator
    }

    func getCacheKey() -> Int {
        message.content.hashValue ^
        (message.thoughts?.hashValue ?? 0) ^
        (message.contentChunks.hashValue) ^
        isDarkMode.hashValue
    }
}

struct ObservableMessageCell: View {
    @ObservedObject var wrapper: ObservableMessageWrapper
    @ObservedObject var viewModel: ChatViewModel
    weak var coordinator: MessageTableView.Coordinator?

    private var bufferHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        return screenHeight * wrapper.bufferMultiplier
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
                    isLoading: wrapper.isLoading
                )
                .environmentObject(viewModel)
                .opacity(wrapper.isArchived ? 0.6 : 1.0)
                .padding(.vertical, 8)
                .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 8)
                .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                    view.frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                }
                .if(wrapper.isLoading && wrapper.isLastMessage) { view in
                    view.overlay(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: StreamingContentHeightKey.self, value: geometry.size.height)
                        }
                    )
                    .onPreferenceChange(StreamingContentHeightKey.self) { height in
                        let heightDiff = abs(height - wrapper.lastReportedHeight)
                        if heightDiff > 5 {
                            wrapper.actualContentHeight = height
                            wrapper.lastReportedHeight = height
                        }
                    }
                }
            }
        }
    }
}

struct StreamingContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
