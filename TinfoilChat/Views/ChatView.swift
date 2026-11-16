//
//  ChatView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import SwiftUI
import SafariServices
import ClerkKit
import RevenueCat
import RevenueCatUI
import TinfoilIcons


// MARK: - ChatContainer

/// The primary SwiftUI container that holds the main chat interface and sidebar navigation.
struct ChatContainer: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel
    @StateObject private var settings = SettingsManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared
    
    @State private var isSidebarOpen = false
    @State private var messageText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var dragOffset: CGFloat = 0
    @State private var showAuthView = false
    @State private var lastBackgroundTime: Date?
    @State private var showPremiumModal = false
    @State private var isVerificationBadgeExpanded = false
    @State private var isVerificationBadgeCollapsed = false
    @State private var sidebarNavigationRequest: ChatNavigationRequest?
    /// The fold while it runs down the middle of the chat area, as when
    /// iPhone Duo is partly folded like a book.
    @State private var verticalFold: CGRect?
    /// Whether the toolbar buttons sit in a vertical bar along the side, as
    /// on a closed iPhone Duo.
    @State private var usesVerticalBar = false

    private var isAnySheetPresented: Bool {
        viewModel.showVerifierSheet || viewModel.showAddSheet || viewModel.showModelSelectorSheet || viewModel.showRateLimitPaywall || viewModel.showDocumentPicker || viewModel.showPhotoPicker || viewModel.showCamera || viewModel.showDocumentScanner || viewModel.showMessageSheet || viewModel.showImageViewer || viewModel.showSidebarSettings || showAuthView || showPremiumModal
    }
    
    // Sidebar constants
    private let sidebarWidth: CGFloat = 300
    private let toolbarPrimaryLabelHeight: CGFloat = 22
    private let sidebarLogoHeight: CGFloat = 28

    private let backgroundTimeThreshold: TimeInterval = 300 // 5 minutes in seconds

    private var toolbarContentColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var showsPrimaryToolbarLabel: Bool {
        if viewModel.activeProject != nil || viewModel.isTemporaryMode {
            return true
        }
        if isSidebarOpen {
            return true
        }
        return authManager.isAuthenticated
            && settings.isCloudSyncEnabled
            && settings.isLocalOnlyModeEnabled
            && viewModel.activeStorageTab == .local
    }

    private var showsStorageLabel: Bool {
        !viewModel.isTemporaryMode && viewModel.activeProject == nil && authManager.isAuthenticated
            && settings.isCloudSyncEnabled && settings.isLocalOnlyModeEnabled
            && viewModel.activeStorageTab == .local
    }

    private var activePromptPreset: PromptPreset? {
        profileManager.promptPreset(for: viewModel.currentChat?.promptPresetId)
    }

    /// With its buttons in a vertical bar, the chat keeps a bar along the top
    /// only for its label, which cannot move into it. The label is left out
    /// when it has nothing to show, as is the logo beside the open sidebar,
    /// so that bar does not take room from the chat.
    private var showsToolbarLabel: Bool {
        guard usesVerticalBar else { return true }
        if viewModel.activeProject != nil { return true }
        if isSidebarOpen { return false }
        return viewModel.isTemporaryMode || showsStorageLabel || activePromptPreset != nil
    }

    /// The shorter bar of a short window, as an iPhone's in landscape, has
    /// room for the chat's label or its prompt's, not both.
    private var isBarTooShortForTwoLabels: Bool {
        verticalSizeClass == .compact && showsPrimaryToolbarLabel
    }

    /// The sidebar is on screen while open and while dragged open.
    private var isSidebarShown: Bool {
        isSidebarOpen || dragOffset != 0
    }

    private var showsSidebarLogo: Bool {
        isSidebarOpen && viewModel.activeProject == nil
    }

    /// With room for both, as on iPad or an open iPhone Duo, the sidebar sits
    /// beside the chat; otherwise it slides over it.
    private var sidebarOverlaysChat: Bool {
        horizontalSizeClass != .regular
    }

    /// The open sidebar covers the chat when it slides over it, so the
    /// chat's own toolbar actions are hidden until it closes.
    private var showsChatToolbarActions: Bool {
        !(isSidebarOpen && sidebarOverlaysChat)
    }
    
    var body: some View {
        NavigationStack {
            mainContent
                .background(Color.chatBackground(isDarkMode: colorScheme == .dark))
                .readsVerticalBar(into: $usesVerticalBar)
        }
        .onChange(of: isAnySheetPresented) { _, presented in
            if presented && isSidebarOpen {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isSidebarOpen = false
                    dragOffset = 0
                }
            }
        }
        .environmentObject(viewModel)
        .onAppear {
            dragOffset = 0
            handleNavigationRequest(viewModel.navigationRequest)
        }
        // A sidebar open beside the chat would cover it once the chat narrows,
        // as when iPhone Duo closes, so it closes to keep the chat in view.
        .onChange(of: sidebarOverlaysChat) { _, overlaysChat in
            guard overlaysChat else { return }
            isSidebarOpen = false
            dragOffset = 0
        }
        .onChange(of: viewModel.navigationRequest) { _, request in
            handleNavigationRequest(request)
        }
        .onChange(of: viewModel.hasPremiumAccess) { _, hasPremiumAccess in
            if !hasPremiumAccess {
                sidebarNavigationRequest = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // App is going to background, record the time
            lastBackgroundTime = Date()
            // Ensure any partial drag is reset to avoid a stuck overlay/sliver
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // App is coming to foreground, check if we should create a new chat
            checkAndCreateNewChatIfNeeded()
            
            // Reset sidebar state when returning from background
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatAuthenticationRequired)) { _ in
            // An account that still holds its session has nothing to sign
            // in to: the refusal shows as the failed request's error.
            if Clerk.shared.session == nil, !showAuthView {
                showAuthView = true
            }
        }
        .alert(viewModel.actionFailure?.title ?? "", isPresented: Binding(
            get: { viewModel.actionFailure != nil },
            set: { if !$0 { viewModel.actionFailure = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.actionFailure?.message ?? "")
        }
        .sheet(isPresented: $viewModel.showVerifierSheet) {
            if let verifierView = viewModel.verifierView {
                verifierView
                    .environmentObject(viewModel)
            }
        }
        .fullScreenCover(isPresented: $viewModel.showImageViewer) {
            ImageViewerOverlay(
                images: viewModel.imageViewerImages,
                initialIndex: viewModel.imageViewerIndex,
                onDismiss: { viewModel.showImageViewer = false },
                loadFullImage: { await viewModel.fullImageData(for: $0) }
            )
        }
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
                .environment(Clerk.shared)
                .environmentObject(authManager)
        }
        .sheet(isPresented: $viewModel.showSidebarSettings, onDismiss: {
            viewModel.focusInputIfPending()
        }) {
            SettingsView()
                .environment(Clerk.shared)
                .environmentObject(authManager)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showPremiumModal) {
            GatedPaywallView {
                showPremiumModal = false
            }
                .onDisappear {
                    // Quick check when paywall is dismissed
                    Task {
                        await authManager.fetchSubscriptionStatus()
                    }
                }
        }
    }
    
    /// The main content layout including chat area and sidebar. The chat and
    /// the sidebar keep their place in it whether the sidebar sits beside the
    /// chat or slides over it, so folding or resizing the app moves them
    /// without rebuilding them.
    private var mainContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                mainSurface
                    .frame(width: geometry.size.width - chatLeadingEdge)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    // The open sidebar covers the chat when it slides over it,
                    // so VoiceOver should only reach the sidebar and the
                    // navigation bar.
                    .accessibilityHidden(isSidebarOpen && sidebarOverlaysChat)

                if sidebarOverlaysChat {
                    sidebarDimming
                }

                activeSidebar
                    .frame(width: shownSidebarWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1)
                    }
                    .offset(x: sidebarOffset(leadingInset: geometry.safeAreaInsets.leading))
                    // Moving the closed sidebar off screen does not remove it
                    // from VoiceOver, which would otherwise read its sections
                    // in the middle of the chat.
                    .accessibilityHidden(!isSidebarOpen)
            }
        }
        .onGeometryChange(for: CGRect?.self) { proxy in
            Self.verticalFold(in: proxy)
        } action: { fold in
            withAnimation(.easeInOut(duration: 0.3)) {
                verticalFold = fold
            }
        }
        .animation(sidebarOverlaysChat ? .easeInOut : .easeInOut(duration: 0.3), value: isSidebarOpen)
        .navigationBarTitleDisplayMode(.inline)
        .adaptiveNavigationBarAppearance(
            for: colorScheme,
            background: .chatBackground(isDarkMode: colorScheme == .dark)
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if viewModel.activeProject != nil && !isSidebarOpen {
                    Button {
                        if isInProjectChat {
                            viewModel.returnToProjectLanding()
                        } else {
                            viewModel.exitProject()
                            withAnimation {
                                isSidebarOpen = true
                            }
                        }
                    } label: {
                        Image(tinfoil: .chevronLeft)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .foregroundColor(toolbarContentColor)
                    }
                    .accessibilityLabel("Back")
                    .accessibleHitTarget()
                } else {
                    Button(action: toggleSidebar) {
                        MenuToXButton(isX: isSidebarOpen)
                            .frame(width: 24, height: 24)
                            .foregroundColor(toolbarContentColor)
                    }
                    .accessibilityLabel(isSidebarOpen ? "Close menu" : "Open menu")
                    .accessibilityHint(isSidebarOpen ? "" : "Shows chats, projects and settings")
                    .accessibleHitTarget()
                }
            }
            .allowsVerticalBar()
            if showsToolbarLabel {
                ToolbarItem(placement: .principal) {
                    toolbarLabel
                }
            }
            if viewModel.activeProject == nil && showsChatToolbarActions {
                ToolbarItem(placement: .navigationBarTrailing) {
                    VerticalBarReader { isInVerticalBar in
                        VerificationStatusIndicator(
                            viewModel: viewModel,
                            isBadgeExpanded: $isVerificationBadgeExpanded,
                            isCollapsed: $isVerificationBadgeCollapsed,
                            showsStatusText: !isInVerticalBar
                        )
                    }
                }
                .allowsVerticalBar()
            }
            // Temporary (incognito) chat toggle, shown on a new chat and on a
            // temporary one: a temporary chat with messages is saved by it.
            if authManager.isAuthenticated && viewModel.activeProject == nil && showsChatToolbarActions && ((viewModel.currentChat?.isBlankChat ?? true) || viewModel.isTemporaryMode) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: toggleTemporaryMode) {
                        if viewModel.isSavingTemporaryChat {
                            ProgressView()
                                .tint(toolbarContentColor)
                        } else {
                            GhostIcon(
                                size: 17,
                                color: toolbarContentColor,
                                style: viewModel.isTemporaryMode ? .filled : .outline
                            )
                        }
                    }
                    .accessibilityLabel(temporaryToggleLabel)
                    .disabled(!viewModel.canUseCurrentChatActions || viewModel.isSavingTemporaryChat)
                    .accessibleHitTarget()
                }
                .allowsVerticalBar()
            }
            // Only show new chat button when chat has messages (not a new/blank chat)
            if authManager.isAuthenticated && viewModel.activeProject == nil && showsChatToolbarActions && !(viewModel.currentChat?.isBlankChat ?? true) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewChat) {
                        Image(tinfoil: .plus)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(toolbarContentColor)
                    }
                    .accessibilityLabel("New chat")
                    .disabled(!viewModel.canUseCurrentChatActions)
                    .accessibleHitTarget()
                }
                .allowsVerticalBar()
                // Starting a chat is the action people reach for most.
                .staysVisibleLonger()
            }
            if !authManager.isAuthenticated {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: showAuthenticationView) {
                        Text("Sign in")
                    }
                }
            }
        }
        .gesture(
            sidebarOverlaysChat ?
            DragGesture()
                .onChanged { gesture in
                    if isSidebarOpen {
                        // When sidebar is open, allow dragging left (negative values)
                        dragOffset = max(-sidebarWidth, min(0, gesture.translation.width))
                    } else {
                        // When sidebar is closed, allow dragging right (positive values)
                        dragOffset = max(0, min(sidebarWidth, gesture.translation.width))
                    }
                }
                .onEnded { gesture in
                    let threshold: CGFloat = 100
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        if isSidebarOpen {
                            // Close if dragged left past threshold
                            if gesture.translation.width < -threshold {
                                isSidebarOpen = false
                            }
                        } else {
                            // Open if dragged right past threshold
                            if gesture.translation.width > threshold {
                                isSidebarOpen = true
                                dismissKeyboard()
                            }
                        }
                        dragOffset = 0
                    }
                } : nil
        )
        .onChange(of: isSidebarShown, initial: true) { _, shown in
            viewModel.sidebarChanges.isShown = shown
        }
        .onChange(of: isSidebarOpen) { _, isOpen in
            if !isOpen {
                // Snap any stray offset back to zero when we finish closing
                dragOffset = 0
            }
            if sidebarOverlaysChat {
                // The overlay swaps which content VoiceOver can reach. After
                // closing, focus starts over at the menu button instead of
                // staying on a sidebar row that is now hidden.
                DispatchQueue.main.async {
                    UIAccessibility.post(
                        notification: isOpen ? .layoutChanged : .screenChanged,
                        argument: nil
                    )
                }
            }
        }
    }
    
    /// The scrollable chat message area
    private var chatArea: some View {
        ChatListView(
            isDarkMode: colorScheme == .dark,
            // A reply the user stopped shows as stopped at once, and a
            // compaction streams no reply.
            isLoading: viewModel.isLoading && !viewModel.isStopping && !viewModel.isCompacting,
            onRequestSignIn: showAuthenticationView,
            viewModel: viewModel,
            messageText: $messageText
        )
        .background(
            Color.chatBackground(isDarkMode: colorScheme == .dark)
                .ignoresSafeArea(edges: .bottom)
        )
        .ignoresSafeArea(edges: .top)
    }
    
    /// The fold the sidebar and the chat sit either side of, while the
    /// sidebar sits beside the chat.
    private var chatFold: CGRect? {
        sidebarOverlaysChat ? nil : verticalFold
    }

    /// Beside a fold, the sidebar fills the page before it.
    private var shownSidebarWidth: CGFloat {
        chatFold?.minX ?? sidebarWidth
    }

    /// The chat's label in the middle of the top bar: the logo beside the
    /// open sidebar, or the project, temporary chat, storage and prompt the
    /// chat is in.
    private var toolbarLabel: some View {
        VStack(spacing: 1) {
            ZStack {
                Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: sidebarLogoHeight)
                    .opacity(showsSidebarLogo ? 1 : 0)
                    .accessibilityLabel("Tinfoil")
                    .accessibilityHidden(!showsSidebarLogo)

                if showsStorageLabel {
                    chatStorageLabel
                        .opacity(isSidebarOpen || isVerificationBadgeExpanded ? 0 : 1)
                        .accessibilityHidden(isSidebarOpen || isVerificationBadgeExpanded)
                }

                if let activeProject = viewModel.activeProject {
                    HStack(spacing: 6) {
                        ProjectFolderIcon(color: activeProject.color, size: 20)
                        Text(activeProject.name)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .foregroundColor(toolbarContentColor)
                    }
                    .opacity(isVerificationBadgeExpanded ? 0 : 1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Project: \(activeProject.name)")
                    .accessibilityHidden(isVerificationBadgeExpanded)
                }

                if viewModel.isTemporaryMode && viewModel.activeProject == nil {
                    HStack(spacing: 6) {
                        GhostIcon(size: 14, color: toolbarContentColor, style: .filled)
                        Text("Temporary")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(toolbarContentColor)
                    }
                    .opacity(isSidebarOpen || isVerificationBadgeExpanded ? 0 : 1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Temporary chat")
                    .accessibilityHidden(isSidebarOpen || isVerificationBadgeExpanded)
                }
            }
            .frame(height: showsPrimaryToolbarLabel ? (showsSidebarLogo ? sidebarLogoHeight : toolbarPrimaryLabelHeight) : 0)

            if let preset = activePromptPreset,
               !isSidebarOpen && !isVerificationBadgeExpanded && !isBarTooShortForTwoLabels {
                HStack(spacing: 4) {
                    Image(tinfoil: preset.icon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(preset.name)
                        .font(.system(.caption2, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(toolbarContentColor.opacity(0.7))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Prompt: \(preset.name)")
            }
        }
        // Centered over the chat rather than the whole screen.
        .offset(x: chatLeadingEdge / 2)
        .animation(.easeInOut(duration: 0.2), value: isSidebarOpen)
        .animation(.easeInOut(duration: 0.35), value: isVerificationBadgeExpanded)
    }

    /// Where the chat starts: past the sidebar while it sits open beside it,
    /// and past the fold whether or not the sidebar is open, so the chat is
    /// never split by it and stays put as the sidebar opens and closes.
    private var chatLeadingEdge: CGFloat {
        if let chatFold {
            return chatFold.maxX
        }
        return isSidebarOpen && !sidebarOverlaysChat ? sidebarWidth : 0
    }

    /// A fold running down the middle of the area `proxy` measures, which
    /// it divides into two pages.
    nonisolated private static func verticalFold(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return proxy.reservedRegions(kind: .division)
            .map(\.frame)
            .first { $0.height > $0.width && $0.minX > 0 && $0.maxX < proxy.size.width }
    }

    /// The sidebar's horizontal offset. A closed one moves past the leading
    /// safe area too, such as a bar or the camera along that edge, so no
    /// sliver of it shows there.
    private func sidebarOffset(leadingInset: CGFloat) -> CGFloat {
        if isSidebarOpen {
            // When open, allow dragging left
            return dragOffset
        }
        // When closed, hide completely (extra 1pt for border)
        return -(shownSidebarWidth + 1 + leadingInset) + dragOffset
    }

    /// Dims the chat under the sidebar while it slides over it.
    private var sidebarDimming: some View {
        Color.black
            .opacity({
                // Compute overlay opacity only when the sidebar is active or being dragged
                let base = 0.4
                let fraction = (dragOffset / sidebarWidth * 0.4)
                return isSidebarOpen ? (base + fraction) : max(0, fraction)
            }())
            .ignoresSafeArea()
            // Prevent a transparent overlay from blocking taps when closed
            .allowsHitTesting(isSidebarOpen || abs(dragOffset) > 0.1)
            .onTapGesture {
                withAnimation {
                    isSidebarOpen = false
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var activeSidebar: some View {
        ChatSidebar(
            isOpen: $isSidebarOpen,
            navigationRequest: $sidebarNavigationRequest,
            overlaysChat: sidebarOverlaysChat,
            viewModel: viewModel,
            changes: viewModel.sidebarChanges,
            authManager: authManager,
            onSubscribe: { showPremiumModal = true },
            onRequestSignIn: showAuthenticationView
        )
        .equatable()
        // VoiceOver's escape gesture (two-finger scrub) closes the menu.
        .accessibilityAction(.escape) {
            withAnimation {
                isSidebarOpen = false
            }
        }
    }

    private var isShowingProjectLanding: Bool {
        viewModel.hasPremiumAccess
            && viewModel.activeProject != nil
            && !viewModel.isViewingProjectChat
    }

    private var isInProjectChat: Bool {
        viewModel.activeProject != nil && viewModel.isViewingProjectChat
    }

    @ViewBuilder
    private var mainSurface: some View {
        if isShowingProjectLanding {
            ProjectPage(viewModel: viewModel)
                .background(Color.settingsBackground(for: colorScheme))
        } else {
            chatArea
        }
    }
    
    // MARK: - Helper Methods

    private func handleNavigationRequest(_ request: ChatNavigationRequest?) {
        guard let request else { return }
        guard PremiumProjectPolicy.allowsNavigation(
            to: request.destination,
            hasPremiumAccess: viewModel.hasPremiumAccess
        ) else {
            sidebarNavigationRequest = nil
            viewModel.consumeNavigationRequest(id: request.id)
            return
        }

        switch request.destination {
        case .chat:
            sidebarNavigationRequest = nil
            messageText = ""
            withAnimation(.easeInOut(duration: 0.3)) {
                isSidebarOpen = false
                dragOffset = 0
            }
        case .projects, .favorites:
            sidebarNavigationRequest = request
            dismissKeyboard()
            withAnimation(.easeInOut(duration: 0.3)) {
                isSidebarOpen = true
                dragOffset = 0
            }
        }

        viewModel.consumeNavigationRequest(id: request.id)
    }
    
    /// Checks if enough time has passed since the app went to background and creates a new chat if needed
    private func checkAndCreateNewChatIfNeeded() {
        guard let lastBackgroundTime = lastBackgroundTime else { return }
        let currentTime = Date()
        let timeSinceBackground = currentTime.timeIntervalSince(lastBackgroundTime)
        
        // Only create a new chat if:
        // 1. Enough time has passed (> 5 minutes)
        // 2. There are existing messages in the current chat
        // 3. User is authenticated (to avoid issues with unauthenticated state)
        // 4. No reply is still running in it, as a long research may be
        if timeSinceBackground > backgroundTimeThreshold && 
           !viewModel.messages.isEmpty && 
           authManager.isAuthenticated &&
           !viewModel.openChatHasLiveRun {
            viewModel.createNewChat()
            messageText = ""
        }
    }
    
    // MARK: - Actions
    
    /// Toggles the sidebar open or closed
    private func toggleSidebar() {
        withAnimation {
            isSidebarOpen.toggle()
            // Dismiss keyboard when opening sidebar
            if isSidebarOpen {
                dismissKeyboard()
            }
        }
    }
    
    /// Dismisses the keyboard
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    /// Shows the authentication view
    private func showAuthenticationView() {
        showAuthView = true
    }
    
    /// Label showing whether current chat is local or cloud-synced.
    /// Only rendered when cloud sync is enabled (see call site).
    private var chatStorageLabel: some View {
        let isLocal = viewModel.activeStorageTab == .local

        return Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            let target: ChatStorageTab = isLocal ? .cloud : .local
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.switchStorageTab(to: target)
            }
        } label: {
            HStack(spacing: 3) {
                if isLocal {
                    Image(tinfoil: .hardDrive)
                        .font(.system(size: 9))
                    Text("Local")
                        .font(.system(.caption2, weight: .medium))
                } else {
                    Image(tinfoil: .cloudSync)
                        .font(.system(size: 9))
                    Text("Cloud")
                        .font(.system(.caption2, weight: .medium))
                }
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocal ? "Local storage" : "Cloud storage")
        .accessibilityHint("Switches between local and cloud chats")
    }
    
    /// Shows the memory view
    
    /// Creates a new chat if the current chat has messages
    private func createNewChat() {
        if !viewModel.messages.isEmpty {
            viewModel.createNewChat()
            messageText = ""
        }
    }

    /// Toggles the temporary (incognito) chat mode. Saving a temporary chat
    /// keeps it open with the draft.
    private func toggleTemporaryMode() {
        let saves = viewModel.isTemporaryMode && !viewModel.messages.isEmpty
        viewModel.toggleTemporaryMode()
        if !saves { messageText = "" }
    }

    private var temporaryToggleLabel: String {
        guard viewModel.isTemporaryMode else { return "Start temporary chat" }
        if viewModel.isSavingTemporaryChat { return "Saving chat" }
        return viewModel.messages.isEmpty ? "Exit temporary chat" : "Save chat"
    }
}

// MARK: - WelcomeView

/// A view that displays a welcome message when no chat messages are present.
struct WelcomeView: View {
    @ObservedObject var authManager: AuthManager
    let onRequestSignIn: () -> Void
    
    var body: some View {
        TabbedWelcomeView(
            authManager: authManager,
            onRequestSignIn: onRequestSignIn
        )
    }
}

/// Welcome view shown when a chat has no messages
struct TabbedWelcomeView: View {
    @ObservedObject var authManager: AuthManager
    let onRequestSignIn: () -> Void
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showPrivacySheet = false

    private static let privacyText = "Your messages are encrypted directly to the AI models running inside secure hardware enclaves. These are hardware-isolated environments powered by confidential computing GPUs with verifiable confidentiality and integrity guarantees. Not even Tinfoil can access your data. This applies to all chats, images, documents, and voice input. Our open-source stack lets you verify this yourself by inspecting the hardware attestation."

    var body: some View {
        VStack(spacing: 24) {
            // Greeting section
            VStack(spacing: 16) {
                if authManager.isAuthenticated {
                    let displayName = getDisplayName(authManager: authManager)
                    if !displayName.isEmpty {
                        Text("Hello, \(displayName)!")
                            .font(.title)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                    } else {
                        AnimatedConfidentialTitle()
                    }
                } else {
                    AnimatedConfidentialTitle()
                }
            }
            .padding(.horizontal, 32)

            Button {
                showPrivacySheet = true
            } label: {
                HStack(spacing: 6) {
                    Text(Constants.WelcomePrivacy.label)
                        .font(.system(size: 15, weight: .medium))
                    Image(tinfoil: .chevronRight)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, Constants.WelcomePrivacy.horizontalPadding)
                .padding(.vertical, Constants.WelcomePrivacy.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: Constants.WelcomePrivacy.cornerRadius)
                        .fill(Color.chatBackground(isDarkMode: colorScheme == .dark))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Constants.WelcomePrivacy.cornerRadius)
                        .strokeBorder(
                            Color.secondary.opacity(Constants.WelcomePrivacy.borderOpacity),
                            lineWidth: Constants.WelcomePrivacy.borderWidth
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
        .sheet(isPresented: $showPrivacySheet) {
            PrivacyExplainerSheet(privacyText: Self.privacyText)
        }
    }

    /// Gets the display name for the user - prioritizes the profile nickname, falls back to first name from auth
    private func getDisplayName(authManager: AuthManager) -> String {
        // First, check if the user has enabled a profile nickname.
        if profileManager.isUsingPersonalization && !profileManager.nickname.isEmpty {
            return profileManager.nickname
        }

        // Fall back to first name from auth data
        if let firstName = authManager.localUserData?["name"] as? String, !firstName.isEmpty {
            return firstName
        }

        return ""
    }
}

/// Popup explaining how chats stay private, shown from the welcome screen
struct PrivacyExplainerSheet: View {
    let privacyText: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        Image(tinfoil: .checkmarkCircle)
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                        Text(Constants.WelcomePrivacy.label)
                            .font(.system(size: 17, weight: .semibold))
                    }

                    Text(privacyText)
                        .font(.system(size: 15))
                        .foregroundColor(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        linkButton(icon: .cpuCheck, title: "Technology", urlString: "https://tinfoil.sh/technology")
                        linkButton(icon: .code2, title: "Source Code", urlString: "https://github.com/tinfoilsh")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.sheetBackground(isDarkMode: colorScheme == .dark).ignoresSafeArea())
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(tinfoil: .xmark)
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close")
                }
            }
            .keepsBarHorizontal()
        }
        .presentationDetents([.medium])
    }

    private func linkButton(icon: TinfoilIcon, title: String, urlString: String) -> some View {
        Button {
            UIApplication.shared.open(URL(string: urlString)!)
        } label: {
            HStack(spacing: 6) {
                Image(tinfoil: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helper Views

/// Animated button that transforms between a menu icon and an X
struct MenuToXButton: View {
    let isX: Bool

    var body: some View {
        ZStack {
            // Top line
            Rectangle()
                .frame(width: 18, height: 2)
                .rotationEffect(.degrees(isX ? 45 : 0))
                .offset(y: isX ? 0 : -6)

            // Middle line
            Rectangle()
                .frame(width: 18, height: 2)
                .opacity(isX ? 0 : 1)

            // Bottom line
            Rectangle()
                .frame(width: 18, height: 2)
                .rotationEffect(.degrees(isX ? -45 : 0))
                .offset(y: isX ? 0 : 6)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isX)
    }
}

/// A shape for custom corner rounding
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

/// Extension for applying rounded corners to views
extension View {
    func corners(_ corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: 15, corners: corners))
    }

    /// Conditionally apply a modifier
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Opens a sheet at page size when the screen presenting it is wide,
    /// as an iPad or an open iPhone Duo is.
    @ViewBuilder
    func pageSheetSizing(in horizontalSizeClass: UserInterfaceSizeClass?) -> some View {
        if horizontalSizeClass == .regular {
            self.presentationSizing(.page)
        } else {
            self
        }
    }
}

/// Verification status indicator for the navigation bar
struct VerificationStatusIndicator: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @Binding var isBadgeExpanded: Bool
    /// Owned by the parent so the badge stays collapsed when the toolbar
    /// removes and re-adds the indicator.
    @Binding var isCollapsed: Bool
    /// In a vertical bar the badge has room for its icon only, whose color
    /// still tells the status.
    let showsStatusText: Bool
    @State private var collapseTask: Task<Void, Never>?

    private var icon: TinfoilIcon {
        if viewModel.isVerified && viewModel.verificationError == nil {
            return .lock
        } else if viewModel.isVerifying {
            return .lockOpened
        } else {
            return .shieldWithExclamation
        }
    }

    private var iconColor: Color {
        if viewModel.isVerified && viewModel.verificationError == nil {
            return .primary
        } else if viewModel.isVerifying {
            return .orange
        } else {
            return .red
        }
    }

    private var statusText: String {
        if viewModel.isVerifying {
            return "Verifying..."
        } else if viewModel.isVerified && viewModel.verificationError == nil {
            return "Privacy verified"
        } else {
            return ""
        }
    }

    private var verificationAccessibilityLabel: String {
        if viewModel.isVerified && viewModel.verificationError == nil {
            return "Privacy verified"
        } else if viewModel.isVerifying {
            return "Verifying privacy"
        } else {
            return "Verification failed"
        }
    }


    var body: some View {
        Button(action: { viewModel.showVerifier() }) {
            HStack(spacing: isCollapsed ? 0 : 4) {
                Image(tinfoil: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 14))

                if showsStatusText && !statusText.isEmpty {
                    // Use the longest possible text as a hidden sizing
                    // reference so the badge width stays stable when the
                    // label changes from "Verifying..." to "Privacy verified".
                    Text("Privacy verified")
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .overlay(alignment: .leading) {
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(iconColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .opacity(isCollapsed ? 0 : 1)
                        .frame(width: isCollapsed ? 0 : nil, alignment: .leading)
                        .clipped()
                }
            }
            .animation(.easeInOut(duration: 0.35), value: isCollapsed)
        }
        .accessibilityLabel(verificationAccessibilityLabel)
        .accessibilityHint("Shows verification details")
        .onAppear {
            if viewModel.isVerified && viewModel.verificationError == nil {
                guard !isCollapsed else { return }
                isBadgeExpanded = showsStatusText
                collapseTask?.cancel()
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Constants.Verification.collapseDelaySeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    isCollapsed = true
                    isBadgeExpanded = false
                }
            } else if viewModel.isVerifying {
                isBadgeExpanded = showsStatusText
                isCollapsed = false
            } else {
                isBadgeExpanded = false
            }
        }
        .onChange(of: viewModel.isVerified) { _, isVerified in
            if isVerified && viewModel.verificationError == nil {
                isBadgeExpanded = showsStatusText
                collapseTask?.cancel()
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Constants.Verification.collapseDelaySeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    isCollapsed = true
                    isBadgeExpanded = false
                }
            }
        }
        .onChange(of: viewModel.isVerifying) { _, isVerifying in
            if isVerifying {
                isBadgeExpanded = showsStatusText
                collapseTask?.cancel()
                collapseTask = nil
                isCollapsed = false
            } else if !viewModel.isVerified {
                isBadgeExpanded = false
            }
        }
        // The badge leaves a horizontal bar for a vertical one, as when
        // iPhone Duo closes, without its text.
        .onChange(of: showsStatusText) { _, showsText in
            if !showsText {
                isBadgeExpanded = false
            }
        }
    }
}

// Helper extension to convert UIView.AnimationCurve to SwiftUI Animation
extension Animation {
    init(curve: UIView.AnimationCurve, duration: Double) {
        switch curve {
        case .easeInOut:
            self = .easeInOut(duration: duration)
        case .easeIn:
            self = .easeIn(duration: duration)
        case .easeOut:
            self = .easeOut(duration: duration)
        case .linear:
            self = .linear(duration: duration)
        @unknown default:
            self = .easeInOut(duration: duration) // Fallback
        }
    }
}
