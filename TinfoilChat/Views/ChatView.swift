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


// MARK: - ChatContainer

/// The primary SwiftUI container that holds the main chat interface and sidebar navigation.
struct ChatContainer: View {
    @Environment(\.colorScheme) var colorScheme
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

    private var showsSidebarLogo: Bool {
        isSidebarOpen && viewModel.activeProject == nil
    }

    /// On iPhone the open sidebar covers the chat, so the chat's own
    /// toolbar actions are hidden until it closes.
    private var showsChatToolbarActions: Bool {
        !(isSidebarOpen && UIDevice.current.userInterfaceIdiom == .phone)
    }
    
    var body: some View {
        NavigationView {
            mainContent
                .background(Color.chatBackground(isDarkMode: colorScheme == .dark))
        }
        .onChange(of: isAnySheetPresented) { _, presented in
            if presented && isSidebarOpen {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isSidebarOpen = false
                    dragOffset = 0
                }
            }
        }
        .navigationViewStyle(.stack)
        .environmentObject(viewModel)
        .onAppear {
            dragOffset = 0
            handleNavigationRequest(viewModel.navigationRequest)
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
            if !showAuthView {
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
    
    /// The main content layout including chat area and sidebar
    private var mainContent: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                // iPad/Mac: Side-by-side layout
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if isSidebarOpen {
                            activeSidebar
                                .frame(width: sidebarWidth)
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.15))
                                        .frame(width: 1)
                                }
                                .transition(.move(edge: .leading))
                        }
                        
                        mainSurface
                            .frame(width: isSidebarOpen ? geometry.size.width - sidebarWidth : geometry.size.width)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isSidebarOpen)
            } else {
                // iPhone: Overlay layout
                ZStack {
                    mainSurface
                        // The open sidebar covers the chat, so VoiceOver should
                        // only reach the sidebar and the navigation bar.
                        .accessibilityHidden(isSidebarOpen)
                    sidebarLayer
                }
            }
        }
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
                        Image(systemName: "chevron.left")
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
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                ZStack {
                    Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: sidebarLogoHeight)
                        .opacity(showsSidebarLogo ? 1 : 0)
                        .accessibilityLabel("Tinfoil")
                        .accessibilityHidden(!showsSidebarLogo)

                    if !viewModel.isTemporaryMode && viewModel.activeProject == nil && authManager.isAuthenticated && settings.isCloudSyncEnabled && settings.isLocalOnlyModeEnabled && viewModel.activeStorageTab == .local {
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

                    if let presetId = viewModel.currentChat?.promptPresetId,
                       let preset = profileManager.promptPreset(for: presetId),
                       !isSidebarOpen && !isVerificationBadgeExpanded {
                        HStack(spacing: 4) {
                            Image(systemName: preset.iconName)
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
                .offset(x: (isSidebarOpen && UIDevice.current.userInterfaceIdiom == .pad) ? sidebarWidth / 2 : 0)
                .animation(.easeInOut(duration: 0.2), value: isSidebarOpen)
                .animation(.easeInOut(duration: 0.35), value: isVerificationBadgeExpanded)
            }
            if viewModel.activeProject == nil && showsChatToolbarActions {
                ToolbarItem(placement: .navigationBarTrailing) {
                    VerificationStatusIndicator(
                        viewModel: viewModel,
                        isBadgeExpanded: $isVerificationBadgeExpanded,
                        isCollapsed: $isVerificationBadgeCollapsed
                    )
                }
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
            }
            // Only show new chat button when chat has messages (not a new/blank chat)
            if authManager.isAuthenticated && viewModel.activeProject == nil && showsChatToolbarActions && !(viewModel.currentChat?.isBlankChat ?? true) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewChat) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(toolbarContentColor)
                    }
                    .accessibilityLabel("New chat")
                    .disabled(!viewModel.canUseCurrentChatActions)
                    .accessibleHitTarget()
                }
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
            UIDevice.current.userInterfaceIdiom == .phone ? 
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
        .onChange(of: isSidebarOpen) { _, isOpen in
            if !isOpen {
                // Snap any stray offset back to zero when we finish closing
                dragOffset = 0
            }
            if UIDevice.current.userInterfaceIdiom == .phone {
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
            isLoading: viewModel.isLoading,
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
    
    /// The sliding sidebar and dimming overlay
    private var sidebarLayer: some View {
        ZStack {
            // Dim overlay
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
            
            // Sidebar with slide transition
            HStack(spacing: 0) {
                activeSidebar
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1)
                    }
                    .offset(x: isSidebarOpen ?
                            (0 + dragOffset) : // When open, allow dragging left
                            (-(sidebarWidth + 1) + dragOffset)) // When closed, hide completely (extra 1pt for border)
                    // Moving the closed sidebar off screen does not remove it
                    // from VoiceOver, which would otherwise read its sections
                    // in the middle of the chat.
                    .accessibilityHidden(!isSidebarOpen)
                Spacer()
            }
        }
        .animation(.easeInOut, value: isSidebarOpen)
    }

    @ViewBuilder
    private var activeSidebar: some View {
        ChatSidebar(
            isOpen: $isSidebarOpen,
            navigationRequest: $sidebarNavigationRequest,
            viewModel: viewModel,
            authManager: authManager,
            onSubscribe: { showPremiumModal = true },
            onRequestSignIn: showAuthenticationView
        )
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
        if timeSinceBackground > backgroundTimeThreshold && 
           !viewModel.messages.isEmpty && 
           authManager.isAuthenticated {
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
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9))
                    Text("Local")
                        .font(.system(.caption2, weight: .medium))
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                    Text("Your chats are private by design")
                        .font(.system(size: 15, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.secondary)
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
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                        Text("Your chats are private by design")
                            .font(.system(size: 17, weight: .semibold))
                    }

                    Text(privacyText)
                        .font(.system(size: 15))
                        .foregroundColor(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        linkButton(icon: "cpu", title: "Technology", urlString: "https://tinfoil.sh/technology")
                        linkButton(icon: "chevron.left.forwardslash.chevron.right", title: "Source Code", urlString: "https://github.com/tinfoilsh")
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
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func linkButton(icon: String, title: String, urlString: String) -> some View {
        Button {
            UIApplication.shared.open(URL(string: urlString)!)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
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

    @ViewBuilder
    func iPadSheetSizing() -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
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
    @State private var collapseTask: Task<Void, Never>?

    private var iconName: String {
        if viewModel.isVerified && viewModel.verificationError == nil {
            return "lock.fill"
        } else if viewModel.isVerifying {
            return "lock.open.fill"
        } else {
            return "exclamationmark.shield.fill"
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
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 14))

                if !statusText.isEmpty {
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
                isBadgeExpanded = true
                collapseTask?.cancel()
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Constants.Verification.collapseDelaySeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    isCollapsed = true
                    isBadgeExpanded = false
                }
            } else if viewModel.isVerifying {
                isBadgeExpanded = true
                isCollapsed = false
            } else {
                isBadgeExpanded = false
            }
        }
        .onChange(of: viewModel.isVerified) { _, isVerified in
            if isVerified && viewModel.verificationError == nil {
                isBadgeExpanded = true
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
                isBadgeExpanded = true
                collapseTask?.cancel()
                collapseTask = nil
                isCollapsed = false
            } else if !viewModel.isVerified {
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
