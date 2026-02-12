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
        .onChange(of: colorScheme) { _, _ in
            setupNavigationBarAppearance()
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
    
    /// Configure navigation bar appearance
    private func setupNavigationBarAppearance() {
        if #available(iOS 26, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.shadowColor = .clear

            updateAllNavigationBars(with: appearance)
        } else {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = colorScheme == .dark ? UIColor(Color.backgroundPrimary) : .white
            appearance.shadowColor = .clear

            updateAllNavigationBars(with: appearance)
        }
    }

    /// Update all navigation bars in the app with the given appearance
    private func updateAllNavigationBars(with appearance: UINavigationBarAppearance) {
        let tintColor: UIColor = colorScheme == .dark ? .white : .black

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = tintColor

        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows {
                    if let navigationBar = window.rootViewController?.navigationController?.navigationBar {
                        navigationBar.standardAppearance = appearance
                        navigationBar.compactAppearance = appearance
                        navigationBar.scrollEdgeAppearance = appearance
                        navigationBar.tintColor = tintColor
                    }
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
        .applyTransparentToolbarIfAvailable()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: toggleSidebar) {
                    MenuToXButton(isX: isSidebarOpen)
                        .frame(width: 24, height: 24)
                        .foregroundColor(toolbarContentColor)
                }
            }
            ToolbarItem(placement: .principal) {
                ZStack {
                    Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 22)
                        .opacity(isSidebarOpen ? 1 : 0)

                    if authManager.isAuthenticated {
                        chatStorageLabel
                            .opacity(isSidebarOpen ? 0 : 1)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isSidebarOpen)
            }
            if authManager.isAuthenticated {
                ToolbarItem(placement: .navigationBarTrailing) {
                    VerificationStatusIndicator(viewModel: viewModel)
                }
            }
            // Only show new chat button when chat has messages (not a new/blank chat)
            if authManager.isAuthenticated && !(viewModel.currentChat?.isBlankChat ?? true) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewChat) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(toolbarContentColor)
                    }
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

    /// Label showing whether current chat is local or cloud-synced
    private var chatStorageLabel: some View {
        let isLocal = viewModel.currentChat?.isLocalOnly ?? true
        let isCloudSync = settings.isCloudSyncEnabled

        return HStack(spacing: 3) {
            if !isCloudSync || isLocal {
                Image(systemName: "internaldrive")
                    .font(.system(size: 9))
                Text("Local")
                    .font(.system(size: 10, weight: .medium))
            } else {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                    .font(.system(size: 9))
                Text("Cloud")
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .foregroundColor(.secondary)
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
    @State private var selectedModelId: String = AppConfig.shared.currentModel?.id ?? ""
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var revenueCat = RevenueCatManager.shared
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
                        proxy.scrollTo(selectedModelId, anchor: .center)
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
    enum Style {
        case compact
        case regular

        var iconSize: CGFloat {
            switch self {
            case .compact: return 20
            case .regular: return 36
            }
        }

        var nameFont: CGFloat {
            switch self {
            case .compact: return 9
            case .regular: return 13
            }
        }

        var cardSize: CGSize {
            switch self {
            case .compact: return CGSize(width: 88, height: 72)
            case .regular: return CGSize(width: 120, height: 110)
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .compact: return 12
            case .regular: return 16
            }
        }

        var checkmarkSize: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 16
            }
        }

        var checkmarkIconSize: CGFloat {
            switch self {
            case .compact: return 6
            case .regular: return 9
            }
        }

        var spacing: CGFloat {
            switch self {
            case .compact: return 4
            case .regular: return 8
            }
        }
    }

    let model: ModelType
    let isSelected: Bool
    let isDarkMode: Bool
    let isEnabled: Bool
    let showPricingLabel: Bool
    var style: Style = .compact
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: style.spacing) {
                // Model icon
                Image(model.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: style.iconSize, height: style.iconSize)
                    .opacity(isEnabled ? 1.0 : 0.7)

                // Model name
                Text(model.displayName)
                    .font(.system(size: style.nameFont, weight: .medium))
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
            .frame(width: style.cardSize.width, height: style.cardSize.height)
            .background(
                ZStack {
                    // Base background
                    if #available(iOS 26, *) {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .fill(.thickMaterial)
                            .opacity(isEnabled ? 1.0 : 0.7)
                    } else {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .fill(Color.chatSurface(isDarkMode: isDarkMode))
                            .opacity(isEnabled ? 1.0 : 0.7)
                    }

                    // Selected state background
                    if isSelected {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .fill(Color.accentPrimary.opacity(0.15))
                    }

                    // Subtle border for unselected enabled items
                    if !isSelected && isEnabled {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                    }

                    // Selection indicator
                    if isSelected {
                        VStack {
                            HStack {
                                Spacer()
                                Circle()
                                    .fill(Color.accentPrimary)
                                    .frame(width: style.checkmarkSize, height: style.checkmarkSize)
                                    .overlay(
                                        Image(systemName: "checkmark")
                                            .font(.system(size: style.checkmarkIconSize, weight: .bold))
                                            .foregroundColor(.white)
                                    )
                            }
                            Spacer()
                        }
                        .padding(style == .compact ? 4 : 8)
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
    func applyTransparentToolbarIfAvailable() -> some View {
        if #available(iOS 26, *) {
            self.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
    }
}

/// Verification status indicator for the navigation bar
struct VerificationStatusIndicator: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @State private var isCollapsed = false
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
            return isCollapsed ? .primary : .green
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


    var body: some View {
        Button(action: { viewModel.showVerifier() }) {
            HStack(spacing: isCollapsed ? 0 : 4) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 14))

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(iconColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(isCollapsed ? 0 : 1)
                        .frame(width: isCollapsed ? 0 : nil, alignment: .leading)
                        .clipped()
                }
            }
            .animation(.easeInOut(duration: 0.35), value: isCollapsed)
        }
        .onAppear {
            if viewModel.isVerified && viewModel.verificationError == nil {
                collapseTask?.cancel()
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Constants.Verification.collapseDelaySeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    isCollapsed = true
                }
            }
        }
        .onChange(of: viewModel.isVerified) { _, isVerified in
            if isVerified && viewModel.verificationError == nil {
                collapseTask?.cancel()
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Constants.Verification.collapseDelaySeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    isCollapsed = true
                }
            }
        }
        .onChange(of: viewModel.isVerifying) { _, isVerifying in
            if isVerifying {
                collapseTask?.cancel()
                collapseTask = nil
                isCollapsed = false
            }
        }
    }
}

/// Model picker for selecting between different AI models
struct ModelPicker: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @EnvironmentObject private var authManager: AuthManager
    @State private var showModelPicker = false

    var body: some View {
        Menu {
            let availableModels = AppConfig.shared.filteredModelTypes(
                isAuthenticated: authManager.isAuthenticated,
                hasActiveSubscription: authManager.hasActiveSubscription
            )

            ForEach(availableModels) { model in
                Button(action: {
                    viewModel.changeModel(to: model)
                }) {
                    Label {
                        Text(model.displayName)
                    } icon: {
                        Image(model.iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                }
                .disabled(viewModel.currentModel == model)
            }
        } label: {
            Image(viewModel.currentModel.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
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
