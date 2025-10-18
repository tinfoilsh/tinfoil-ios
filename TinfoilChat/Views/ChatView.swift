//
//  ChatView.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.


import SwiftUI
import SafariServices
import Clerk
import RevenueCat
import RevenueCatUI


// MARK: - ChatContainer

/// The primary SwiftUI container that holds the main chat interface and sidebar navigation.
struct ChatContainer: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel
    @StateObject private var settings = SettingsManager.shared
    
    @State private var isSidebarOpen = UIDevice.current.userInterfaceIdiom == .pad
    @State private var messageText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var dragOffset: CGFloat = 0
    @State private var showAuthView = false
    @State private var showSettings = false
    @State private var lastBackgroundTime: Date?
    @State private var shouldCreateNewChatAfterSubscription = false
    @State private var showPremiumModal = false
    
    // Sidebar constants
    private let sidebarWidth: CGFloat = 300

    private let backgroundTimeThreshold: TimeInterval = 300 // 5 minutes in seconds

    private var toolbarButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.white
    }

    private var toolbarButtonStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.white
    }

    private var toolbarContentColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    
    var body: some View {
        NavigationView {
            mainContent
                .background(Color.chatBackground(isDarkMode: colorScheme == .dark))
        }
        .navigationViewStyle(.stack)
        .environmentObject(viewModel)
        .onAppear {
            setupNavigationBarAppearance()
            
            // Ensure sidebar is closed on initial appearance
            isSidebarOpen = false
            dragOffset = 0
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
            
            // Ensure sidebar is fully closed when returning from background
            withAnimation(.easeOut(duration: 0.2)) {
                isSidebarOpen = false
                dragOffset = 0
            }
        }
        .sheet(isPresented: $viewModel.showVerifierSheet) {
            if let verifierView = viewModel.verifierView {
                verifierView
                    .environmentObject(viewModel)
            }
        }
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
                .environment(Clerk.shared)
                .environmentObject(authManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPremiumModal) {
            PaywallView(displayCloseButton: true)
                .onPurchaseCompleted { _ in
                    showPremiumModal = false
                    shouldCreateNewChatAfterSubscription = true
                }
                .onDisappear {
                    // Quick check when paywall is dismissed
                    Task {
                        await authManager.fetchSubscriptionStatus()
                        if authManager.hasActiveSubscription {
                            shouldCreateNewChatAfterSubscription = true
                        }
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SubscriptionStatusUpdated"))) { _ in
            // Force refresh when subscription status changes
            if authManager.hasActiveSubscription && shouldCreateNewChatAfterSubscription {
                shouldCreateNewChatAfterSubscription = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let language = settings.selectedLanguage == "System" ? nil : settings.selectedLanguage
                    viewModel.createNewChat(language: language)
                }
            }
        }
    }
    
    /// Configure navigation bar appearance to be solid color
    private func setupNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        
        // Always use dark navigation bar for main chat view since logo is white
        appearance.backgroundColor = UIColor(Color.backgroundPrimary)
        appearance.shadowColor = .clear
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    /// The main content layout including chat area and sidebar
    private var mainContent: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                // iPad/Mac: Side-by-side layout
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if isSidebarOpen {
                            ChatSidebar(isOpen: $isSidebarOpen, viewModel: viewModel, authManager: authManager)
                                .frame(width: sidebarWidth)
                                .transition(.move(edge: .leading))
                        }
                        
                        chatArea
                            .frame(width: isSidebarOpen ? geometry.size.width - sidebarWidth : geometry.size.width)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isSidebarOpen)
            } else {
                // iPhone: Overlay layout
                ZStack {
                    chatArea
                    sidebarLayer
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: toggleSidebar) {
                    MenuToXButton(isX: isSidebarOpen)
                        .frame(width: 24, height: 24)
                        .foregroundColor(.white)
                }
            }
            ToolbarItem(placement: .principal) {
                Image("navbar-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
            }
            // Only show toolbar items when chat has messages (not a new/blank chat)
            if authManager.isAuthenticated && !(viewModel.currentChat?.isBlankChat ?? true) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ModelPicker(viewModel: viewModel)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewChat) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(toolbarContentColor)
                    }
                }
            }
            if !authManager.isAuthenticated {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sign in", systemImage: "person.crop.circle") {
                        showAuthenticationView()
                    }
                    .foregroundColor(toolbarContentColor)
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
        }
    }
    
    /// The scrollable chat message area
    private var chatArea: some View {
        ChatScrollView(
            messages: viewModel.messages,
            isDarkMode: colorScheme == .dark,
            isLoading: viewModel.isLoading,
            onRequestSignIn: showAuthenticationView,
            viewModel: viewModel,
            messageText: $messageText,
        )
        .background(Color.chatBackground(isDarkMode: colorScheme == .dark))
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
            
            // Sidebar with slide transition
            HStack(spacing: 0) {
                ChatSidebar(isOpen: $isSidebarOpen, viewModel: viewModel, authManager: authManager)
                    .frame(width: sidebarWidth)
                    .offset(x: isSidebarOpen ?
                            (0 + dragOffset) : // When open, allow dragging left
                            (-(sidebarWidth + 1) + dragOffset)) // When closed, hide completely (extra 1pt for border)
                Spacer()
            }
        }
        .animation(.easeInOut, value: isSidebarOpen)
    }
    
    // MARK: - Helper Methods
    
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
            let language = settings.selectedLanguage == "System" ? nil : settings.selectedLanguage
            viewModel.createNewChat(language: language)
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
    
    /// Shows the settings view
    private func showSettingsView() {
        showSettings = true
    }
    
    /// Shows the memory view
    
    /// Creates a new chat if the current chat has messages
    private func createNewChat() {
        if !viewModel.messages.isEmpty {
            let language = settings.selectedLanguage == "System" ? nil : settings.selectedLanguage
            viewModel.createNewChat(language: language)
            messageText = ""
        }
    }
}

// MARK: - ChatScrollView

/// A scrollable view that displays chat messages
struct ChatScrollView: View {
    
    // MARK: - Properties
    
    let messages: [Message]
    let isDarkMode: Bool
    let isLoading: Bool
    let onRequestSignIn: () -> Void
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var messageText: String
    
    // Scroll management
    @State private var scrollViewProxy: ScrollViewProxy?
    @State private var userHasScrolled = false
    @State private var isAtBottom = false

    // Keyboard handling
    @State private var keyboardHeight: CGFloat = 0
    @State private var isKeyboardVisible = false
    
    // Computed property for context messages
    private var contextMessages: ArraySlice<Message> {
        messages.suffix(SettingsManager.shared.maxMessages)
    }
    
    // Added property to track the index where archived messages start
    private var archivedMessagesStartIndex: Int {
        max(0, messages.count - SettingsManager.shared.maxMessages)
    }

    private let scrollCoordinateSpaceName = "ChatScrollCoordinateSpace"
    private let scrollMovementThreshold: CGFloat = 0.1
    private let scrollSettleDelay: TimeInterval = 0.3

    @State private var scrollEndWorkItem: DispatchWorkItem?
    @State private var lastObservedScrollOffset: CGFloat = 0
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages ScrollView
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo -> Color in
                        let offset = geo.frame(in: .named(scrollCoordinateSpaceName)).minY
                        DispatchQueue.main.async {
                            updateScrollActivity(with: offset)
                        }
                        return Color.clear
                    }
                    .frame(height: 0)
                    LazyVStack(spacing: 0) {
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
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                let actualIndex = index
                                
                                // Check if we should show the archived divider
                                if actualIndex != 0 && actualIndex == archivedMessagesStartIndex {
                                    // Divider for archived messages
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
                                
                                MessageView(
                                    message: message,
                                    isDarkMode: isDarkMode
                                )
                                .id(message.id)
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

                    // Bottom anchor point placed outside the VStack so it always exists
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(
                            GeometryReader { geometry -> Color in
                                let isCurrentlyAtBottom = isViewFullyVisible(geometry)
                                if isAtBottom != isCurrentlyAtBottom {
                                    DispatchQueue.main.async {
                                        isAtBottom = isCurrentlyAtBottom
                                        if isCurrentlyAtBottom {
                                            userHasScrolled = false
                                            viewModel.isScrollInteractionActive = false
                                            cancelScrollSettlingWork()
                                        }
                                    }
                                }
                                return Color.clear
                            }
                        )
                }
                // Reset scroll state when switching chats
                .id(viewModel.currentChat?.createdAt ?? Date.distantPast)
                .ignoresSafeArea(.keyboard)
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            cancelScrollSettlingWork()
                            if value.translation.height > 0 && isLoading {
                                userHasScrolled = true
                            }
                            // Dismiss keyboard when scrolling up
                            if value.translation.height > 10 && isKeyboardVisible {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                            if !viewModel.isScrollInteractionActive {
                                viewModel.isScrollInteractionActive = true
                            }
                            scheduleScrollSettlingCheck()
                        }
                        .onEnded { _ in
                            scheduleScrollSettlingCheck()
                        }
                )
                .onTapGesture {
                    if isKeyboardVisible {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                .onChange(of: messages) { oldMessages, newMessages in
                    let previousCount = oldMessages.count
                    let newCount = newMessages.count

                    guard newCount >= previousCount else { return }

                    if newCount > previousCount {
                        let appendedMessages = newMessages.suffix(newCount - previousCount)
                        let includesUserMessage = appendedMessages.contains { $0.role == .user }
                        let wasInitialLoad = previousCount == 0
                        let shouldAutoFollow = includesUserMessage || wasInitialLoad

                        if shouldAutoFollow {
                            userHasScrolled = false
                            requestJumpToBottom(animated: false)
                            viewModel.isScrollInteractionActive = false
                            cancelScrollSettlingWork()
                        }
                    }
                }
                // When the selected chat changes, just reset bookkeeping
                .onChange(of: viewModel.currentChat?.createdAt) { _, _ in
                    userHasScrolled = false
                    viewModel.isScrollInteractionActive = false
                    cancelScrollSettlingWork()
                    requestJumpToBottom(animated: false)
                }
                .onAppear {
                    scrollViewProxy = proxy
                    viewModel.isScrollInteractionActive = false
                    cancelScrollSettlingWork()
                    requestJumpToBottom(animated: false)
                }
                .onDisappear {
                    cancelScrollSettlingWork()
                    viewModel.isScrollInteractionActive = false
                }
                .coordinateSpace(name: scrollCoordinateSpaceName)

                .overlay(alignment: .bottom) {
                    if !isAtBottom && !messages.isEmpty && !isKeyboardVisible {
                        Button(action: {
                            cancelScrollSettlingWork()
                            userHasScrolled = false
                            let targetId: AnyHashable = messages.last?.id ?? "bottom"
                            proxy.scrollTo(targetId, anchor: .bottom)
                            DispatchQueue.main.async {
                                withAnimation(.interpolatingSpring(stiffness: 150, damping: 20)) {
                                    proxy.scrollTo(targetId, anchor: .bottom)
                                }
                                isAtBottom = true
                                viewModel.isScrollInteractionActive = false
                            }
                        }) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.gray.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .padding(.bottom, 16)
                        .padding(.trailing, 16)
                        .transition(.opacity)
                    }
                }
                .background(Color.chatBackground(isDarkMode: isDarkMode))
            }
            
            // Message input view
            if UIDevice.current.userInterfaceIdiom == .phone {
                // iPhone: Full width input
                MessageInputView(messageText: $messageText, viewModel: viewModel)
                    .background(
                        RoundedCorner(radius: 16, corners: [.topLeft, .topRight])
                            .fill(Color.chatSurface(isDarkMode: isDarkMode))
                            .edgesIgnoringSafeArea(.bottom)
                    )
                    .environmentObject(viewModel.authManager ?? AuthManager())
            } else {
                // iPad/Mac: Centered input with max width
                HStack {
                    Spacer(minLength: 0)
                    MessageInputView(messageText: $messageText, viewModel: viewModel)
                        .frame(maxWidth: 600)
                        .background(
                            RoundedCorner(radius: 16, corners: [.topLeft, .topRight])
                                .fill(Color.chatSurface(isDarkMode: isDarkMode))
                        )
                        .environmentObject(viewModel.authManager ?? AuthManager())
                    Spacer(minLength: 0)
                }
                .background(
                    Color.clear
                        .frame(height: 1)
                        .edgesIgnoringSafeArea(.bottom)
                )
            }
            
        }
        .onAppear {
            setupKeyboardObservers()
        }
        .onDisappear {
            removeKeyboardObservers()
        }
    }

    private func updateScrollActivity(with offset: CGFloat) {
        let delta = abs(offset - lastObservedScrollOffset)
        lastObservedScrollOffset = offset

        if delta > scrollMovementThreshold {
            if !viewModel.isScrollInteractionActive {
                viewModel.isScrollInteractionActive = true
            }
            scheduleScrollSettlingCheck()
        } else if viewModel.isScrollInteractionActive {
            scheduleScrollSettlingCheck()
        }
    }

    private func scheduleScrollSettlingCheck() {
        cancelScrollSettlingWork()
        let workItem = DispatchWorkItem {
            viewModel.isScrollInteractionActive = false
            scrollEndWorkItem = nil
        }
        scrollEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollSettleDelay, execute: workItem)
    }

    private func cancelScrollSettlingWork() {
        scrollEndWorkItem?.cancel()
        scrollEndWorkItem = nil
    }

    private func requestJumpToBottom(animated: Bool) {
        guard let proxy = scrollViewProxy else { return }
        let bottomAnchor: AnyHashable = "bottom"
        let lastMessageId = messages.last?.id
        cancelScrollSettlingWork()

        let performScroll = {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
            if let lastMessageId {
                proxy.scrollTo(lastMessageId, anchor: .bottom)
            }
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    performScroll()
                }
            } else {
                performScroll()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                performScroll()
            }

            userHasScrolled = false
            isAtBottom = true
            viewModel.isScrollInteractionActive = false
        }
    }

    // MARK: - Keyboard Handling

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { notification in
            guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = keyboardFrame.height
                isKeyboardVisible = true
                
                // Only auto-scroll to bottom when keyboard appears if we're already at the bottom
                if !userHasScrolled {
                    scrollViewProxy?.scrollTo("bottom", anchor: .bottom)
                }
            }
        }

        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = 0
                isKeyboardVisible = false
            }
        }
    }
    
    private func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
    // MARK: - Helper Methods

    /// Checks if a view is fully visible in the scroll view
    private func isViewFullyVisible(_ geometry: GeometryProxy) -> Bool {
        // Get the key window using the new API for iOS 15+
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        
        guard let window = keyWindow else { return false }
        
        // Convert the frame to global coordinates
        let globalFrame = geometry.frame(in: .global)
        
        // Get safe area insets
        let safeAreaInsets = window.safeAreaInsets
        
        // Calculate visible screen height excluding keyboard and input view
        // We don't add keyboard height here to avoid creating extra scrollable space
        let visibleHeight = UIScreen.main.bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
        
        // Add some slack to the visibility check (allow 20 points overflow)
        let slack: CGFloat = 40
        let isVisible = globalFrame.minY >= -slack && globalFrame.maxY <= (visibleHeight + slack)
        
        return isVisible
    }
}

// MARK: - WelcomeView

/// A view that displays a welcome message when no chat messages are present.
struct WelcomeView: View {
    let isDarkMode: Bool
    @ObservedObject var authManager: AuthManager
    let onRequestSignIn: () -> Void
    
    var body: some View {
        TabbedWelcomeView(
            isDarkMode: isDarkMode,
            authManager: authManager,
            onRequestSignIn: onRequestSignIn
        )
    }
}

/// A tabbed welcome view that allows model selection
struct TabbedWelcomeView: View {
    let isDarkMode: Bool
    @ObservedObject var authManager: AuthManager
    let onRequestSignIn: () -> Void
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel
    @State private var selectedModelId: String = ""
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var revenueCat = RevenueCatManager.shared
    @State private var refreshID = UUID()
    @State private var showPremiumModal = false
    @State private var isWaitingForSubscription = false
    
    private var availableModels: [ModelType] {
        return AppConfig.shared.filteredModelTypes(
            isAuthenticated: authManager.isAuthenticated,
            hasActiveSubscription: authManager.hasActiveSubscription
        )
    }
    
    private var canUseModel: (ModelType) -> Bool {
        { model in
            let isAuthenticated = authManager.isAuthenticated
            let hasSubscription = authManager.hasActiveSubscription
            return model.isFree || (isAuthenticated && hasSubscription)
        }
    }
    
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
            
            // Model selection tabs
            VStack(spacing: 2) {
                Text("Choose an AI model")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 32)
                
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(availableModels) { model in
                                ModelTab(
                                    model: model,
                                    isSelected: selectedModelId == model.id,
                                    isDarkMode: isDarkMode,
                                    isEnabled: canUseModel(model),
                                    showPricingLabel: !(authManager.isAuthenticated && authManager.hasActiveSubscription)
                                ) {
                                    if !canUseModel(model) {
                                        guard authManager.isAuthenticated else {
                                            onRequestSignIn()
                                            return
                                        }
                                        // Set clerk_user_id attribute right before showing paywall
                                        if authManager.isAuthenticated, let clerkUserId = authManager.localUserData?["id"] as? String {
                                            Purchases.shared.attribution.setAttributes(["clerk_user_id": clerkUserId])
                                        }
                                        showPremiumModal = true
                                    } else {
                                        selectModel(model)
                                    }
                                }
                                .id(model.id)
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                    .frame(height: 100)
                    .onAppear {
                        // Scroll to selected model when view appears
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo(selectedModelId, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: selectedModelId) { _, newModelId in
                        // Scroll to newly selected model
                        withAnimation {
                            proxy.scrollTo(newModelId, anchor: .center)
                        }
                    }
                }
            }
            
            // Show loading view while waiting for subscription (where the subscription prompt used to be)
            if isWaitingForSubscription && !(authManager.isAuthenticated && authManager.hasActiveSubscription) {
                InlineSubscriptionLoadingView(
                    authManager: authManager,
                    onSuccess: {
                        isWaitingForSubscription = false
                        refreshID = UUID()
                        
                        // Create a new chat to show premium models
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if !viewModel.messages.isEmpty {
                                let language = settings.selectedLanguage == "System" ? nil : settings.selectedLanguage
                                viewModel.createNewChat(language: language)
                            }
                        }
                    },
                    onTimeout: {
                        isWaitingForSubscription = false
                    }
                )
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
        .onAppear {
            selectedModelId = viewModel.currentModel.id
        }
        .onChange(of: viewModel.currentModel) { _, newModel in
            selectedModelId = newModel.id
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SubscriptionStatusUpdated"))) { _ in
            // Refresh view when subscription status changes
            refreshID = UUID()
        }
        .id(refreshID)
        .sheet(isPresented: $showPremiumModal) {
            PaywallView(displayCloseButton: true)
                .onPurchaseCompleted { _ in
                    showPremiumModal = false
                    isWaitingForSubscription = true
                }
                .onDisappear {
                    // Quick check when paywall is dismissed
                    Task {
                        await authManager.fetchSubscriptionStatus()
                    }
                }
        }
    }
    
    
    private func selectModel(_ model: ModelType) {
        guard model.id != viewModel.currentModel.id else { return }
        
        if !canUseModel(model) {
            guard authManager.isAuthenticated else {
                onRequestSignIn()
                return
            }
            // Set clerk_user_id attribute right before showing paywall
            if authManager.isAuthenticated, let clerkUserId = authManager.localUserData?["id"] as? String {
                Purchases.shared.attribution.setAttributes(["clerk_user_id": clerkUserId])
            }
            showPremiumModal = true
            return
        }
        
        selectedModelId = model.id
        viewModel.changeModel(to: model)
    }
    
    /// Gets the display name for the user - prioritizes nickname from settings, falls back to first name from auth
    private func getDisplayName(authManager: AuthManager) -> String {
        // First, check if user has set a nickname in settings
        if settings.isPersonalizationEnabled && !settings.nickname.isEmpty {
            return settings.nickname
        }
        
        // Fall back to first name from auth data
        if let firstName = authManager.localUserData?["name"] as? String, !firstName.isEmpty {
            return firstName
        }
        
        return ""
    }
}

/// Individual model tab component
struct ModelTab: View {
    let model: ModelType
    let isSelected: Bool
    let isDarkMode: Bool
    let isEnabled: Bool
    let showPricingLabel: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                // Model icon
                Image(model.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .opacity(isEnabled ? 1.0 : 0.7)
                
                // Model name
                Text(model.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isEnabled ? 1.0 : 0.7)
                
                // Free/Premium indicator (only shown for non-premium users)
                if showPricingLabel {
                    Text(model.isFree ? "Free" : "Premium")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(isEnabled ? (model.isFree ? .green : .orange) : .gray)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isEnabled ? 
                                      (model.isFree ? Color.green : Color.orange).opacity(0.1) :
                                      Color.gray.opacity(0.1))
                        )
                }
            }
            .foregroundColor(isEnabled ? (isSelected ? .primary : .secondary) : .gray)
            .frame(width: 88, height: 72)
            .background(
                ZStack {
                    // Base background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.chatSurface(isDarkMode: isDarkMode))
                        .opacity(isEnabled ? 1.0 : 0.7)
                    
                    // Selected state background
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentPrimary.opacity(0.15))
                    }
                    
                    // Subtle border for unselected enabled items
                    if !isSelected && isEnabled {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                    }
                    
                    // Selection indicator - small dot in top right
                    if isSelected {
                        VStack {
                            HStack {
                                Spacer()
                                Circle()
                                    .fill(Color.accentPrimary)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 6, weight: .bold))
                                            .foregroundColor(.white)
                                    )
                            }
                            Spacer()
                        }
                        .padding(4)
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Helper Views

/// Animated button that transforms between a menu icon and an X
struct MenuToXButton: View {
    let isX: Bool
    @Environment(\.colorScheme) var colorScheme
    
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
        .foregroundColor(.white)
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
}

/// Model picker for selecting between different AI models
struct ModelPicker: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showModelPicker = false
    @State private var refreshID = UUID()

    private var buttonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.white
    }

    private var buttonStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.white
    }
    
    var body: some View {
        Button(action: {
            showModelPicker.toggle()
        }) {
            Image(viewModel.currentModel.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        }
        .popover(isPresented: $showModelPicker) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Select Model")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                
                Divider()
                
                // Get filtered models based on authentication and subscription status
                let availableModels = AppConfig.shared.filteredModelTypes(
                    isAuthenticated: authManager.isAuthenticated, 
                    hasActiveSubscription: authManager.hasActiveSubscription
                )
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(availableModels) { model in
                            Button(action: {
                                viewModel.changeModel(to: model)
                                showModelPicker = false
                            }) {
                                HStack(alignment: .center, spacing: 12) {
                                    Image(model.iconName)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 24, height: 24)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.modelNameSimple)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        
                                        Text(model.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    
                                    Spacer()
                                    
                                    if viewModel.currentModel == model {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color.accentPrimary)
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .background(viewModel.currentModel == model ? Color.gray.opacity(0.1) : Color.clear)
                            
                            if model != availableModels.last {
                                Divider()
                                    .padding(.leading, 52)
                            }
                        }
                    }
                }
            }
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SubscriptionStatusUpdated"))) { _ in
            // Force refresh model picker when subscription changes
            refreshID = UUID()
        }
        .id(refreshID)
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
