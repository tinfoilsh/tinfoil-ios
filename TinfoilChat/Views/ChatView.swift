//
//  ChatView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.


import SwiftUI
import SafariServices


// MARK: - ChatContainer

/// The primary SwiftUI container that holds the main chat interface and sidebar navigation.
struct ChatContainer: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel
    @StateObject private var settings = SettingsManager.shared
    
    @State private var isSidebarOpen = false
    @State private var messageText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var dragOffset: CGFloat = 0
    @State private var showAuthView = false
    @State private var showSettings = false
    @State private var lastBackgroundTime: Date?
    
    private let backgroundTimeThreshold: TimeInterval = 60 // 1 minute in seconds
    
    var body: some View {
        NavigationView {
            mainContent
                .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .environmentObject(viewModel)
        .onAppear {
            setupNavigationBarAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // App is going to background, record the time
            lastBackgroundTime = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // App is coming to foreground, check if we should create a new chat
            checkAndCreateNewChatIfNeeded()
        }
        .sheet(isPresented: $viewModel.showVerifierSheet) {
            if let verifierView = viewModel.verifierView {
                verifierView
                    .environmentObject(viewModel)
            }
        }
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
    
    /// Configure navigation bar appearance to be solid color
    private func setupNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color(hex: "#111827"))
        appearance.shadowColor = .clear
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    /// The main content layout including chat area and sidebar
    private var mainContent: some View {
        ZStack {
            chatArea
            sidebarLayer
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
                    .frame(height: 28)
            }
            if authManager.isAuthenticated {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ModelPicker(viewModel: viewModel)
                }
                // New chat button
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewChat) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(.white, lineWidth: 1)
                                )
                                .frame(width: 24, height: 24)
                            
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.black)
                        }
                    }
                }
            }
            if !authManager.isAuthenticated {
                // Show sign in button for non-authenticated users
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: showAuthenticationView) {
                        Text("Sign in")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.white)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(.white, lineWidth: 1)
                                    )
                            )
                    }
                }
            }
        }
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    if isSidebarOpen {
                        // When sidebar is open, allow dragging left (negative values)
                        dragOffset = max(-300, min(0, gesture.translation.width))
                    } else {
                        // When sidebar is closed, allow dragging right (positive values)
                        dragOffset = max(0, min(300, gesture.translation.width))
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
                            }
                        }
                        dragOffset = 0
                    }
                }
        )
    }
    
    /// The scrollable chat message area
    private var chatArea: some View {
        ChatScrollView(
            messages: viewModel.messages,
            isDarkMode: colorScheme == .dark,
            isLoading: viewModel.isLoading,
            viewModel: viewModel,
            messageText: $messageText,
        )
        .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)     
    }
    
    /// The sliding sidebar and dimming overlay
    private var sidebarLayer: some View {
        ZStack {
            // Dim overlay
            Color.black
                .opacity(isSidebarOpen ? 
                    (0.4 + (dragOffset / 300 * 0.4)) : // When open, fade out as we drag left
                    (dragOffset / 300 * 0.4)) // When closed, fade in as we drag right
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isSidebarOpen = false
                    }
                }
            
            // Sidebar with slide transition
            HStack(spacing: 0) {
                ChatSidebar(isOpen: $isSidebarOpen, viewModel: viewModel, authManager: authManager)
                    .frame(width: 300)
                    .offset(x: isSidebarOpen ? 
                        (0 + dragOffset) : // When open, allow dragging left
                        (-300 + dragOffset)) // When closed, allow dragging right
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
        // 1. Enough time has passed (> 1 minute)
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
        }
    }
    
    /// Shows the authentication view
    private func showAuthenticationView() {
        showAuthView = true
    }
    
    /// Shows the settings view
    private func showSettingsView() {
        showSettings = true
    }
    
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
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var messageText: String
    
    // Scroll management
    @State private var scrollViewProxy: ScrollViewProxy?
    @State private var userHasScrolled = false
    @State private var lastMessageCount = 0
    @State private var isAtBottom = false
    
    // Keyboard handling
    @State private var keyboardHeight: CGFloat = 0
    @State private var isKeyboardVisible = false
    
    // Haptic feedback generator
    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    
    // Computed property for context messages
    private var contextMessages: ArraySlice<Message> {
        messages.suffix(AppConfig.shared.maxMessagesPerRequest)
    }
    
    // Added property to track the index where archived messages start
    private var archivedMessagesStartIndex: Int {
        max(0, messages.count - AppConfig.shared.maxMessagesPerRequest)
    }
    
    @State private var isScrolling = false
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages ScrollView
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if messages.isEmpty {
                            WelcomeView(isDarkMode: isDarkMode, authManager: viewModel.authManager)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if index != 0 && index == archivedMessagesStartIndex {
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
                                .padding(.horizontal, 8)
                                .opacity(index < archivedMessagesStartIndex ? 0.6 : 1.0)
                            }
                            
                            // Bottom anchor point without extra padding
                            Color.clear
                                .frame(height: 10)
                                .id("bottom")
                                .background(
                                    GeometryReader { geometry -> Color in
                                        let isCurrentlyAtBottom = isViewFullyVisible(geometry)
                                        if isAtBottom != isCurrentlyAtBottom {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                isAtBottom = isCurrentlyAtBottom
                                                if isCurrentlyAtBottom {
                                                    userHasScrolled = false
                                                }
                                            }
                                        }
                                        return Color.clear
                                    }
                                )
                        }
                    }
                }
                .ignoresSafeArea(.keyboard)
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            isScrolling = true
                            if value.translation.height > 0 && isLoading {
                                userHasScrolled = true
                            }
                        }
                        .onEnded { _ in
                            isScrolling = false
                        }
                )
                .onTapGesture {
                    if isKeyboardVisible {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                .onChange(of: messages) { _, newMessages in
                    // If this is a new message (not just an update to the last message)
                    if newMessages.count > lastMessageCount {
                        lastMessageCount = newMessages.count
                        userHasScrolled = false // Reset scroll state for new messages
                        withAnimation {
                            scrollViewProxy?.scrollTo("bottom", anchor: .bottom)
                        }
                    } else if !userHasScrolled {
                        // Only scroll if user hasn't manually scrolled up
                        withAnimation {
                            scrollViewProxy?.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    scrollViewProxy = proxy
                    lastMessageCount = messages.count
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !isAtBottom && !messages.isEmpty && !isKeyboardVisible {
                        Button(action: {
                            // First scroll without animation to override momentum
                            proxy.scrollTo("bottom", anchor: .bottom)
                            // Then immediately scroll again with animation for smooth finish
                            DispatchQueue.main.async {
                                withAnimation(.interpolatingSpring(stiffness: 150, damping: 20)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
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
                .background(isDarkMode ? Color.backgroundPrimary : Color.white)
            }
            
            // Message input view
            MessageInputView(messageText: $messageText, viewModel: viewModel)
                .background(
                    RoundedCorner(radius: 16, corners: [.topLeft, .topRight])
                        .fill(isDarkMode ? Color(hex: "2C2C2E") : Color(hex: "F2F2F7"))
                        .edgesIgnoringSafeArea(.bottom)
                )
                .environmentObject(viewModel.authManager ?? AuthManager())
            
        }
        .onAppear {
            setupKeyboardObservers()
            softHaptic.prepare()
        }
        .onDisappear {
            removeKeyboardObservers()
        }
        .onChange(of: messages.last?.content) { oldContent, newContent in
            if settings.hapticFeedbackEnabled,
               let old = oldContent,
               let new = newContent,
               old != new {
                let addedContent = String(new.dropFirst(old.count))
                if addedContent.count > 1 {
                    softHaptic.impactOccurred(intensity: 0.3)
                }
            }
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
    let authManager: AuthManager?
    
    var body: some View {
        TabbedWelcomeView(isDarkMode: isDarkMode, authManager: authManager)
    }
}

/// A tabbed welcome view that allows model selection
struct TabbedWelcomeView: View {
    let isDarkMode: Bool
    let authManager: AuthManager?
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel
    @State private var selectedModelId: String = ""
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var revenueCat = RevenueCatManager.shared
    
    private var availableModels: [ModelType] {
        return AppConfig.shared.availableModels
    }
    
    private var canUseModel: (ModelType) -> Bool {
        { model in
            let isAuthenticated = authManager?.isAuthenticated ?? false
            let hasSubscription = authManager?.hasActiveSubscription ?? false
            return model.isFree || (isAuthenticated && hasSubscription)
        }
    }
    
    var body: some View {
        VStack(spacing: 32) {
            // Greeting section
            VStack(spacing: 16) {
                if let authManager = authManager,
                   authManager.isAuthenticated {
                    let displayName = getDisplayName(authManager: authManager)
                    if !displayName.isEmpty {
                        Text("Hello, \(displayName)!")
                            .font(.title)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("How can I assist you?")
                            .font(.title)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("How can I assist you?")
                        .font(.title)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                }
                
                Text("This conversation is completely private, nobody can see your messages — not even Tinfoil.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Model selection tabs
            VStack(spacing: 16) {
                Text("Choose your AI model")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.primary)
                
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 16)
                ], spacing: 16) {
                    ForEach(availableModels) { model in
                        ModelTab(
                            model: model,
                            isSelected: selectedModelId == model.id,
                            isDarkMode: isDarkMode,
                            isEnabled: canUseModel(model),
                            showPricingLabel: !(authManager?.isAuthenticated == true && authManager?.hasActiveSubscription == true)
                        ) {
                            selectModel(model)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            
            // Subscription prompt for non-premium users
            if !(authManager?.isAuthenticated == true && authManager?.hasActiveSubscription == true) {
                subscriptionPrompt
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .onAppear {
            selectedModelId = viewModel.currentModel.id
        }
        .onChange(of: viewModel.currentModel) { _, newModel in
            selectedModelId = newModel.id
        }
    }
    
    // Subscription prompt view
    private var subscriptionPrompt: some View {
        SubscriptionPromptView(authManager: authManager)
    }
    
    private func selectModel(_ model: ModelType) {
        guard model.id != viewModel.currentModel.id && canUseModel(model) else { return }
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
                        .fill(isDarkMode ? Color(hex: "2C2C2E") : Color(hex: "F2F2F7"))
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
        .disabled(!isEnabled)
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
}

/// Model picker for selecting between different AI models
struct ModelPicker: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @EnvironmentObject private var authManager: AuthManager
    @State private var showModelPicker = false
    
    var body: some View {
        Button(action: {
            showModelPicker.toggle()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white, lineWidth: 1)
                    )
                    .frame(width: 24, height: 24)
                
                Image(viewModel.currentModel.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            }
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

