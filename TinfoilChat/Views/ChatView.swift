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
                Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                    .opacity(isSidebarOpen ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isSidebarOpen)
            }
            // Only show toolbar items when chat has messages (not a new/blank chat)
            if authManager.isAuthenticated && !(viewModel.currentChat?.isBlankChat ?? true) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ModelPicker(viewModel: viewModel)
                }

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
                    if #available(iOS 26, *) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.thickMaterial)
                            .opacity(isEnabled ? 1.0 : 0.7)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.chatSurface(isDarkMode: isDarkMode))
                            .opacity(isEnabled ? 1.0 : 0.7)
                    }

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
