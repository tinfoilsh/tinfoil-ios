//
//  ChatSidebar.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import SafariServices

/// Search results, unlike the root list, surface project chats for Premium
/// users; temporary and undecryptable chats are always excluded.
func isSearchResultSidebarChat(_ chat: ChatListSummary, hasPremiumAccess: Bool) -> Bool {
    !chat.isTemporary
        && !chat.decryptionFailed
        && PremiumProjectPolicy.includesChat(
            projectId: chat.projectId,
            hasPremiumAccess: hasPremiumAccess
        )
}

func isRootSidebarChat(_ chat: ChatListSummary) -> Bool {
    !chat.isTemporary && !chat.decryptionFailed && chat.projectId == nil
}

func resolveSidebarSearchChat(
    id: String,
    remoteResults: [Chat],
    loadedChats: [Chat]
) -> Chat? {
    remoteResults.first(where: { $0.id == id })
        ?? loadedChats.first(where: { $0.id == id })
}

func isSidebarChatSearchEnabled(
    isAuthenticated: Bool,
    isCloudSyncEnabled: Bool,
    activeTab: ChatStorageTab
) -> Bool {
    isAuthenticated && isCloudSyncEnabled && activeTab == .cloud
}

struct ChatSidebar: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(Clerk.self) private var clerk
    @Binding var isOpen: Bool
    @Binding var navigationRequest: ChatNavigationRequest?
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject var authManager: AuthManager
    let onSubscribe: () -> Void
    let onRequestSignIn: () -> Void
    @State private var editingChatId: String? = nil
    @State private var editingTitle: String = ""
    @State private var deletingChatId: String? = nil
    @State private var showDeleteAlert: Bool = false

    @State private var isTabSwitching: Bool = false
    @State private var isFavoritesExpanded: Bool = false
    @State private var isProjectsExpanded: Bool = false
    @State private var isChatsExpanded: Bool = true
    @State private var chatSearchTerm: String = ""
    @StateObject private var chatSearch = ChatSearchController()
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var cloudSync = CloudSyncService.shared
    @ObservedObject private var syncHealth = SyncHealthStore.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    private var activeTab: ChatStorageTab {
        viewModel.activeStorageTab
    }

    private var filteredChats: [ChatListSummary] {
        let source: [ChatListSummary]
        if authManager.isAuthenticated && settings.isCloudSyncEnabled {
            switch activeTab {
            case .cloud:
                source = viewModel.cloudSidebarSummaries
            case .local:
                source = viewModel.localSidebarSummaries
            }
        } else {
            // When cloud sync is off, all chats are local
            source = viewModel.localSidebarSummaries
        }
        // Temporary and project chats are never listed in the root chat
        // sidebar. Chats that failed to decrypt are hidden entirely; they
        // stay in storage so re-decryption can recover them once the
        // right key is active, at which point they reappear here.
        return source.filter(isRootSidebarChat)
    }

    // Encrypted server-side search over synced chats. Only offered on
    // the cloud tab: local-only chats never reach the enclave, so the
    // index cannot know about them.
    private var isChatSearchEnabled: Bool {
        isSidebarChatSearchEnabled(
            isAuthenticated: authManager.isAuthenticated,
            isCloudSyncEnabled: settings.isCloudSyncEnabled,
            activeTab: activeTab
        )
    }

    private var isChatSearchActive: Bool {
        isChatSearchEnabled
            && !chatSearchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResultChats: [ChatListSummary] {
        guard isChatSearchActive else { return [] }
        // Enclave unavailable (older deploy, no eligible key): degrade
        // to filtering the locally loaded titles so the box still does
        // something useful. Draw from the loaded cloud chats with the
        // search-result predicate so project chats stay findable here
        // too, matching the server-backed results.
        guard chatSearch.available else {
            let needle = chatSearchTerm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return viewModel.cloudSidebarSummaries.filter {
                isSearchResultSidebarChat($0, hasPremiumAccess: viewModel.hasPremiumAccess)
                    && !$0.isBlankChat
                    && $0.title.lowercased().contains(needle)
            }
        }
        return chatSearch.results
            .map { ChatListSummary(from: $0) }
            .filter { isSearchResultSidebarChat($0, hasPremiumAccess: viewModel.hasPremiumAccess) }
    }

    private var displayedChats: [ChatListSummary] {
        isChatSearchActive ? searchResultChats : filteredChats
    }

    private var searchUserId: String? {
        authManager.localUserId
    }

    // Timer to update relative time strings
    @State private var timeUpdateTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var currentTime = Date()
    
    // Helper function to format relative time
    private func relativeTimeString(from date: Date) -> String {
        let now = currentTime  // Use currentTime instead of Date() to trigger updates
        let difference = now.timeIntervalSince(date)
        
        if difference < 60 { // Less than 1 minute
            return "Just now"
        } else if difference < 3600 { // Less than 1 hour
            let minutes = Int(difference / 60)
            return "\(minutes)m ago"
        } else if difference < 86400 { // Less than 1 day
            let hours = Int(difference / 3600)
            return "\(hours)h ago"
        } else if difference < 604800 { // Less than 1 week
            let days = Int(difference / 86400)
            return "\(days)d ago"
        } else if difference < 2592000 { // Less than 30 days
            let weeks = Int(difference / 604800)
            return "\(weeks)w ago"
        } else {
            let months = Int(difference / 2592000)
            return "\(months)mo ago"
        }
    }

    /// Empty when the updated time would read the same as the created
    /// time, so rows don't repeat "14m ago · Updated 14m ago".
    private func updatedTimeString(for chat: ChatListSummary) -> String {
        let created = relativeTimeString(from: chat.createdAt)
        let updated = relativeTimeString(from: chat.updatedAt)
        guard updated != created else { return "" }
        return "Updated \(updated.lowercased())"
    }
    
    var body: some View {
        sidebarContent
            .frame(width: 300)
            .background(colorScheme == .dark ? Color.sidebarBackground(for: colorScheme) : Color.white)
            .ignoresSafeArea(edges: .bottom)
            .onReceive(timeUpdateTimer) { _ in
                currentTime = Date()
            }
            .alert("Delete Chat", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {
                deletingChatId = nil
            }
            Button("Delete", role: .destructive) {
                if let id = deletingChatId {
                    viewModel.deleteChat(id)
                    if filteredChats.isEmpty {
                        viewModel.createNewChat(isLocalOnly: activeTab == .local || !settings.isCloudSyncEnabled)
                    }
                }
                deletingChatId = nil
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
        }
        // Covers sign-out (id -> nil) and account switches: search
        // results hold decrypted titles, so they must never survive
        // into another account's session.
        .onChange(of: searchUserId) { _, _ in
            chatSearchTerm = ""
            chatSearch.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CheckAuthState"))) { _ in
            Task {
                if clerk.user != nil && !authManager.isAuthenticated {
                    await authManager.initializeAuthState()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AuthenticationCompleted"))) { _ in
            // Close sidebar to take user to main chat view after successful authentication
            withAnimation {
                isOpen = false
            }
        }
        .task {
            await viewModel.loadProjects()
        }
        .onChange(of: viewModel.shouldExpandProjectsInSidebar) { _, shouldExpand in
            if shouldExpand {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isProjectsExpanded = true
                }
                viewModel.shouldExpandProjectsInSidebar = false
            }
        }
        .onChange(of: viewModel.hasPremiumAccess) { _, hasPremiumAccess in
            if !hasPremiumAccess {
                isProjectsExpanded = false
            }
        }
    }

    private func applyNavigationRequest(
        _ request: ChatNavigationRequest?,
        scrollProxy: ScrollViewProxy
    ) {
        guard let request else { return }
        guard request.destination != .chat else {
            navigationRequest = nil
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            if request.destination == .projects {
                isFavoritesExpanded = false
                isProjectsExpanded = true
            } else {
                isFavoritesExpanded = true
                isProjectsExpanded = false
            }
            scrollProxy.scrollTo(request.destination, anchor: .top)
        }

        navigationRequest = nil
    }
    
    @ViewBuilder
    private var recoveryBanner: some View {
        if authManager.isAuthenticated && settings.isCloudSyncEnabled && viewModel.isPasskeyRecoverySkipped {
            Button {
                withAnimation { isOpen = false }
                Task { await viewModel.reattemptPasskeyRecovery() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "key.slash")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloud sync is paused")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("Tap to unlock with your passkey")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
            }
            .buttonStyle(.plain)
        }
    }

    private var sidebarContent: some View {
        let projectColors = viewModel.projects.reduce(into: [String: String]()) {
            $0[$1.id] = $1.color
        }
        return VStack(spacing: 0) {
            recoveryBanner
            ScrollViewReader { scrollProxy in
                // A List rather than a ScrollView so chat rows get the system
                // swipe actions; the row chrome is stripped so the sidebar
                // keeps its own look.
                List {
                    if let upsellVariant {
                        upsellCard(upsellVariant)
                            .sidebarRow(top: 8)
                    }

                    if authManager.isAuthenticated && settings.isCloudSyncEnabled {
                        favoritesSection(projectColors: projectColors)

                        if viewModel.hasPremiumAccess {
                            projectsSection
                                .sidebarRow(top: 8)
                                .id(ChatNavigationDestination.projects)
                        }
                    }

                    chatsSectionHeader
                        .sidebarRow(top: 8)

                    if isTabSwitching {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .sidebarRow()
                    } else if isChatsExpanded {
                        if authManager.isAuthenticated && settings.isCloudSyncEnabled && settings.isLocalOnlyModeEnabled {
                            cloudLocalTabSwitcher
                                .sidebarRow(top: 8)
                        }

                        chatsDescription
                            .sidebarRow(top: 8)

                        if isChatSearchEnabled {
                            chatSearchField
                                .sidebarRow(top: 8)
                        }

                        chatList(projectColors: projectColors)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .applyAlwaysBounceIfAvailable()
                .refreshable {
                    await authManager.initializeAuthState()
                    await authManager.safeguards.refresh()
                    await viewModel.performFullSync()
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    applyNavigationRequest(navigationRequest, scrollProxy: scrollProxy)
                }
                .onChange(of: navigationRequest) { _, request in
                    applyNavigationRequest(request, scrollProxy: scrollProxy)
                }
            }

            Divider()
                .background(Color.gray.opacity(0.3))

            settingsButton
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .safeAreaPadding(.bottom)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var chatSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Search chats...", text: $chatSearchTerm)
                .font(.subheadline)
                .textFieldStyle(PlainTextFieldStyle())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search chats")
            if !chatSearchTerm.isEmpty {
                Button {
                    chatSearchTerm = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gray.opacity(0.1), lineWidth: 1)
        )
        .onChange(of: chatSearchTerm) { _, term in
            chatSearch.updateTerm(term, userId: searchUserId)
        }
    }

    @ViewBuilder
    private var chatSearchStatusRow: some View {
        if chatSearch.isIndexing {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                Text("Building search index...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if chatSearch.isSearching && searchResultChats.isEmpty {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if searchResultChats.isEmpty {
            Text("No matching chats")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    /// Whether a row may be renamed or deleted, matching the inline
    /// edit/trash controls and the accessibility actions on the row.
    private func canManageChat(_ chat: ChatListSummary) -> Bool {
        authManager.isAuthenticated && !chat.isBlankChat && !chat.decryptionFailed
    }

    /// Swipe right to pin, swipe left to delete or rename, mirroring the
    /// project page's chat rows.
    private func chatRowSwipeActions<Content: View>(
        _ chat: ChatListSummary,
        content: Content
    ) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if viewModel.canPinChat(chat) || profileManager.isChatPinned(chat.id) {
                    Button {
                        viewModel.toggleChatPin(chat)
                    } label: {
                        Label(
                            profileManager.isChatPinned(chat.id) ? "Unpin" : "Pin",
                            systemImage: profileManager.isChatPinned(chat.id) ? "pin.slash" : "pin"
                        )
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if canManageChat(chat) {
                    Button(role: .destructive) {
                        confirmDelete(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        startEditing(chat)
                    } label: {
                        Label("Rename", systemImage: "square.and.pencil")
                    }
                    .tint(.gray)
                }
            }
    }

    @ViewBuilder
    private func chatList(projectColors: [String: String]) -> some View {
        ForEach(displayedChats) { chat in
            chatRowSwipeActions(chat, content: ChatListItem(
                chat: chat,
                safeguards: authManager.safeguards,
                isSelected: viewModel.selectedChatId == chat.id,
                isEditing: editingChatId == chat.id,
                editingTitle: $editingTitle,
                createdTimeString: chat.isBlankChat ? "" : relativeTimeString(from: chat.createdAt),
                updatedTimeString: chat.isBlankChat ? "" : updatedTimeString(for: chat),
                isSyncing: !chat.isBlankChat && cloudSync.pendingUploadChatIds.contains(chat.id),
                syncFailed: !chat.isBlankChat && syncHealth.failedChats[chat.id] != nil,
                isGenerating: viewModel.isChatStreaming(chat.id),
                isPinned: profileManager.isChatPinned(chat.id),
                projectColor: chat.projectId.flatMap { projectColors[$0] },
                onSelect: {
                    if isChatSearchActive {
                        if !chatSearch.available {
                            viewModel.openSummaryChat(
                                id: chat.id,
                                projectId: chat.projectId,
                                isLocalOnly: chat.isLocalOnly
                            )
                            return
                        }
                        guard let fullChat = resolveSidebarSearchChat(
                            id: chat.id,
                            remoteResults: chatSearch.results,
                            loadedChats: viewModel.chats
                        ) else { return }
                        viewModel.openSearchResult(fullChat)
                    } else {
                        viewModel.selectChat(id: chat.id, isLocalOnly: chat.isLocalOnly)
                    }
                },
                onEdit: {
                    if editingChatId == chat.id {
                        let editedChatId = chat.id
                        let editedTitle = editingTitle
                        Task {
                            await viewModel.updateChatTitle(editedChatId, newTitle: editedTitle)
                            if editingChatId == editedChatId {
                                editingChatId = nil
                            }
                        }
                    } else {
                        startEditing(chat)
                    }
                },
                onDelete: { confirmDelete(chat) },
                showEditDelete: authManager.isAuthenticated
            )
            .contextMenu {
                if viewModel.canPinChat(chat) || profileManager.isChatPinned(chat.id) {
                    Button {
                        viewModel.toggleChatPin(chat)
                    } label: {
                        Label(
                            profileManager.isChatPinned(chat.id) ? "Unpin" : "Pin",
                            systemImage: profileManager.isChatPinned(chat.id) ? "pin.slash" : "pin"
                        )
                    }
                }
                if viewModel.hasPremiumAccess && !chat.isBlankChat && !chat.decryptionFailed {
                    ForEach(viewModel.projects.filter { $0.decryptionFailed != true }) { project in
                        Button {
                            Task {
                                await viewModel.moveChatToProject(chatId: chat.id, projectId: project.id)
                            }
                        } label: {
                            Label {
                                Text("Add to \(project.name)")
                            } icon: {
                                ProjectFolderIcon(color: project.color, size: 22)
                            }
                        }
                    }
                }
                if canManageChat(chat) {
                    Divider()
                    Button {
                        startEditing(chat)
                    } label: {
                        Label("Rename", systemImage: "square.and.pencil")
                    }
                    Button(role: .destructive) {
                        confirmDelete(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            })
            .sidebarRow(top: 6, bottom: 6)
        }

        if isChatSearchActive {
            chatSearchStatusRow
                .sidebarRow(top: 6, bottom: 8)
        } else if viewModel.hasMoreChats && activeTab != .local {
            if viewModel.isLoadingMore {
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .sidebarRow(top: 6, bottom: 8)
            } else {
                loadMoreButton
                    .sidebarRow(top: 6, bottom: 8)
            }
        }
    }

    /// Emits the header and each favorite as separate list rows so the
    /// rows pick up swipe actions.
    @ViewBuilder
    private func favoritesSection(projectColors: [String: String]) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFavoritesExpanded.toggle()
            }
        } label: {
            HStack {
                Label("Favorites", systemImage: "pin")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .rotationEffect(.degrees(isFavoritesExpanded ? 0 : -90))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Favorites")
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isFavoritesExpanded ? "Expanded" : "Collapsed")
        .sidebarRow(top: 16)
        .id(ChatNavigationDestination.favorites)

        if isFavoritesExpanded {
            if visibleFavoriteChats.isEmpty {
                Text("Pin cloud chats for quick access.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .sidebarRow(top: 10)
            } else {
                ForEach(visibleFavoriteChats) { chat in
                    favoriteChatRow(chat, projectColors: projectColors)
                        .sidebarRow(top: 10)
                }
            }
        }
    }

    private var visibleFavoriteChats: [Chat] {
        viewModel.favoriteChats.filter {
            PremiumProjectPolicy.includesChat(
                projectId: $0.projectId,
                hasPremiumAccess: viewModel.hasPremiumAccess
            )
        }
    }

    private func favoriteChatRow(_ chat: Chat, projectColors: [String: String]) -> some View {
        let summary = ChatListSummary(from: chat)
        return chatRowSwipeActions(summary, content: ChatListItem(
            chat: summary,
            safeguards: authManager.safeguards,
            isSelected: viewModel.currentChat?.id == chat.id,
            isEditing: editingChatId == chat.id,
            editingTitle: $editingTitle,
            createdTimeString: relativeTimeString(from: chat.createdAt),
            updatedTimeString: updatedTimeString(for: summary),
            isSyncing: cloudSync.pendingUploadChatIds.contains(chat.id),
            syncFailed: syncHealth.failedChats[chat.id] != nil,
            isGenerating: viewModel.isChatStreaming(chat.id),
            isPinned: true,
            showPinnedIndicator: false,
            projectColor: chat.projectId.flatMap { projectColors[$0] },
            onSelect: { viewModel.openSearchResult(chat) },
            onEdit: {
                if editingChatId == chat.id {
                    let editedChatId = chat.id
                    let editedTitle = editingTitle
                    Task {
                        await viewModel.updateChatTitle(editedChatId, newTitle: editedTitle)
                        if editingChatId == editedChatId {
                            editingChatId = nil
                        }
                    }
                } else {
                    startEditing(summary)
                }
            },
            onDelete: { confirmDelete(summary) },
            showEditDelete: true
        )
        .contextMenu {
            Button {
                viewModel.toggleChatPin(chat)
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }

            if viewModel.hasPremiumAccess && chat.projectId != nil {
                Button {
                    Task {
                        await viewModel.removeChatFromProject(chatId: chat.id)
                    }
                } label: {
                    Label("Remove from Project", systemImage: "arrow.uturn.left")
                }
            }

            if viewModel.hasPremiumAccess {
                ForEach(viewModel.projects.filter {
                    $0.decryptionFailed != true && $0.id != chat.projectId
                }) { project in
                    Button {
                        Task {
                            await viewModel.moveChatToProject(chatId: chat.id, projectId: project.id)
                        }
                    } label: {
                        Label {
                            Text(chat.projectId == nil ? "Add to \(project.name)" : "Move to \(project.name)")
                        } icon: {
                            ProjectFolderIcon(color: project.color, size: 22)
                        }
                    }
                }
            }

            Divider()
            Button {
                startEditing(summary)
            } label: {
                Label("Rename", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                confirmDelete(summary)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        })
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        if #available(iOS 26, *) {
            Button {
                Task { await viewModel.loadMoreChats() }
            } label: {
                Text("Load More")
                    .font(.system(.callout, weight: .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glass)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        } else {
            Button {
                Task { await viewModel.loadMoreChats() }
            } label: {
                Text("Load More")
                    .foregroundColor(.primary)
                    .font(.system(.callout, weight: .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(UIColor.secondarySystemBackground).opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.gray.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var settingsGearIcon: some View {
        Image(systemName: "gear")
            .overlay(alignment: .topTrailing) {
                if syncHealth.needsAttention() {
                    Circle()
                        .fill(Color.orange)
                        .frame(
                            width: Constants.CloudSync.attentionBadgeSize,
                            height: Constants.CloudSync.attentionBadgeSize
                        )
                        .offset(x: 4, y: -4)
                        .accessibilityLabel(Constants.CloudSync.attentionAccessibilityLabel)
                }
            }
    }

    private enum UpsellVariant {
        case account
        case premium
    }

    /// Mirrors the webapp's sidebar upsell: hidden while auth is still
    /// resolving or once the user has Premium; signed-out users are asked
    /// to create an account, signed-in free users to subscribe.
    private var upsellVariant: UpsellVariant? {
        if authManager.isLoading || authManager.hasActiveSubscription { return nil }
        return authManager.isAuthenticated ? .premium : .account
    }

    private struct UpsellFeature: Identifiable {
        let systemImage: String
        let text: String
        var id: String { text }
    }

    private func upsellFeatures(for variant: UpsellVariant) -> [UpsellFeature] {
        switch variant {
        case .premium:
            return [
                UpsellFeature(systemImage: "mic", text: "Speech-to-text voice input"),
                UpsellFeature(systemImage: "sparkles", text: "No daily request limits"),
                UpsellFeature(systemImage: "folder", text: "Create projects to chat with files"),
            ]
        case .account:
            return [
                UpsellFeature(systemImage: "bubble.left.and.bubble.right", text: "Keep your chat history"),
                UpsellFeature(systemImage: "icloud", text: "Encrypted sync across devices"),
                UpsellFeature(systemImage: "pin", text: "Save your favorite chats"),
            ]
        }
    }

    private func upsellCard(_ variant: UpsellVariant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get more out of Tinfoil Chat")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(upsellFeatures(for: variant)) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.systemImage)
                            .font(.caption)
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                            .frame(width: 16)
                        Text(feature.text)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            switch variant {
            case .premium:
                upsellCTAButton("Subscribe to Premium", action: onSubscribe)
                    .accessibilityHint("Opens subscription options")
            case .account:
                upsellCTAButton("Create account", action: onRequestSignIn)
                    .accessibilityHint("Opens sign in")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gray.opacity(0.1), lineWidth: 1)
        )
    }

    private func upsellCTAButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.tinfoilAccentDark)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(iOS 26, *) {
            Button {
                viewModel.showSidebarSettings = true
            } label: {
                HStack {
                    settingsGearIcon
                    Text("Settings")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.glass)
        } else {
            Button {
                viewModel.showSidebarSettings = true
            } label: {
                HStack {
                    settingsGearIcon
                    Text("Settings")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color.sidebarButtonBackground(for: colorScheme))
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(colorScheme == .dark ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(8)
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isProjectsExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Projects", systemImage: "folder")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    if viewModel.isLoadingProjects {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .rotationEffect(.degrees(isProjectsExpanded ? 0 : -90))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Projects")
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isProjectsExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isProjectsExpanded ? "Collapses the projects list" : "Expands the projects list")

            if isProjectsExpanded {
                Button {
                    Task {
                        await viewModel.createProject()
                    }
                } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemBackground).opacity(0.3))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                ForEach(viewModel.projects) { project in
                    Button {
                        Task {
                            await viewModel.enterProject(projectId: project.id)
                            withAnimation {
                                isOpen = false
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if project.decryptionFailed == true {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.orange)
                            } else {
                                ProjectFolderIcon(color: project.color)
                            }
                            Text(project.name)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemBackground).opacity(0.3))
                        .cornerRadius(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(project.decryptionFailed == true)
                    .accessibilityLabel(project.decryptionFailed == true ? "\(project.name), encrypted, unavailable" : project.name)
                    .accessibilityHint(project.decryptionFailed == true ? "" : "Opens the project")
                }
            }
        }
    }

    @ViewBuilder
    private var chatsDescription: some View {
        if authManager.isAuthenticated && settings.isCloudSyncEnabled && settings.isLocalOnlyModeEnabled {
            Group {
                if activeTab == .local {
                    Text("Local chats are stored only on this device and won't sync across devices.")
                } else {
                    Text("Your chats are encrypted and synced to the cloud. The encryption key is only stored on this device and never sent to Tinfoil.")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chatsSectionHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isChatsExpanded.toggle()
            }
        } label: {
            HStack {
                Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .rotationEffect(.degrees(isChatsExpanded ? 0 : -90))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chats")
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isChatsExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isChatsExpanded ? "Collapses the chat list" : "Expands the chat list")
    }
    
    private var cloudLocalTabSwitcher: some View {
        HStack(spacing: 0) {
            Button(action: { switchTab(to: .cloud) }) {
                HStack(spacing: 4) {
                    Image(systemName: "icloud")
                        .font(.caption)
                    Text("Cloud")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(activeTab == .cloud
                              ? (colorScheme == .dark ? Color(UIColor.systemBackground) : Color.white)
                              : Color.clear)
                        .shadow(color: activeTab == .cloud ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
                )
                .foregroundColor(activeTab == .cloud ? .primary : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Cloud chats")
            .accessibilityAddTraits(activeTab == .cloud ? .isSelected : [])

            Button(action: { switchTab(to: .local) }) {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.caption)
                    Text("Local")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(activeTab == .local
                              ? (colorScheme == .dark ? Color(UIColor.systemBackground) : Color.white)
                              : Color.clear)
                        .shadow(color: activeTab == .local ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
                )
                .foregroundColor(activeTab == .local ? .primary : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Local chats")
            .accessibilityAddTraits(activeTab == .local ? .isSelected : [])
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    private func switchTab(to tab: ChatStorageTab) {
        guard activeTab != tab else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isTabSwitching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            viewModel.switchStorageTab(to: tab)
            withAnimation(.easeInOut(duration: 0.2)) {
                isTabSwitching = false
            }
        }
    }

    private func startEditing(_ chat: ChatListSummary) {
        editingChatId = chat.id
        editingTitle = chat.title
    }
    
    private func confirmDelete(_ chat: ChatListSummary) {
        deletingChatId = chat.id
        showDeleteAlert = true
    }
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func applyAlwaysBounceIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollBounceBehavior(.always)
        } else {
            self
        }
    }

    /// Strips the system list row chrome so sidebar content lays out as it
    /// would in a plain stack, with the sidebar's own horizontal margin.
    func sidebarRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct ChatListItem: View {
    let chat: ChatListSummary
    @ObservedObject var safeguards: SafeguardsStore
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingTitle: String
    let createdTimeString: String
    let updatedTimeString: String
    var isSyncing: Bool = false
    var syncFailed: Bool = false
    var isGenerating: Bool = false
    var isPinned: Bool = false
    var showPinnedIndicator: Bool = true
    var projectColor: String? = nil
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let showEditDelete: Bool
    
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if isEditing {
                        TextField("Chat Title", text: $editingTitle)
                            .textFieldStyle(PlainTextFieldStyle())
                            .foregroundColor(.primary)
                            .onSubmit {
                                onEdit()
                            }
                            .accessibilityLabel("Chat title")
                        
                        // Save and Cancel buttons for editing mode
                        HStack(spacing: 12) {
                            Button(action: onEdit) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.primary)
                            }
                            .accessibilityLabel("Save title")
                            Button(action: { editingTitle = chat.title; onEdit() }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(.primary)
                            }
                            .accessibilityLabel("Cancel editing")
                        }
                    } else {
                        HStack(spacing: 4) {
                            if chat.projectId != nil {
                                ProjectFolderIcon(color: projectColor, size: 18)
                                    .accessibilityHidden(true)
                            }
                            if isPinned && showPinnedIndicator {
                                Image(systemName: "pin.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .accessibilityHidden(true)
                            }
                            Text(chat.title)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if safeguards.isFlagged(chat.id) {
                                Image(systemName: "flag.fill")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .accessibilityHidden(true)
                            }
                            
                            if chat.isBlankChat {
                                // Blue dot indicator for new chats
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                            
                            Spacer()
                        }
                        
                        if isSelected && showEditDelete && !chat.isBlankChat {
                            // Edit and Delete buttons (not shown for new/blank chats)
                            HStack(spacing: 12) {
                                Button(action: onEdit) {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundColor(.gray)
                                }
                                Button(action: onDelete) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
                
                // Timestamp inside the cell
                if !isEditing {
                    if !createdTimeString.isEmpty {
                        HStack(spacing: 4) {
                            (Text(createdTimeString)
                                .foregroundColor(Color(UIColor.secondaryLabel))
                                + Text(updatedTimeString.isEmpty ? "" : " · \(updatedTimeString)")
                                .foregroundColor(Color(UIColor.tertiaryLabel)))
                                .font(.caption)
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else if syncFailed {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else if isSyncing {
                                Image(systemName: "icloud.and.arrow.up")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }
                    } else {
                        // Placeholder for new chats to maintain consistent height
                        Text(" ")
                            .font(.caption)
                            .frame(height: 14) // Same height as timestamp text
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color(UIColor.secondarySystemBackground) : Color(UIColor.secondarySystemBackground).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.1), lineWidth: 1)
        )
        // Collapse the row into a single VoiceOver element when not editing so
        // the title, timestamp and state read as one item; the nested edit and
        // delete buttons are surfaced as custom actions instead of becoming
        // unreachable elements inside the row button.
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityAddTraits(rowAccessibilityTraits)
        .accessibilityHint(rowAccessibilityHint)
        .if(showEditDelete && !chat.isBlankChat && !chat.decryptionFailed && !isEditing) { view in
            view
                .accessibilityAction(named: Text("Rename")) { onEdit() }
                .accessibilityAction(named: Text("Delete")) { onDelete() }
        }
    }

    private var rowAccessibilityLabel: String {
        if chat.decryptionFailed {
            return "Encrypted chat. Failed to decrypt, wrong key."
        }
        var components = [chat.title.isEmpty ? "Untitled chat" : chat.title]
        if chat.projectId != nil {
            components.append("Project chat")
        }
        if isPinned {
            components.append("Favorite")
        }
        if safeguards.isFlagged(chat.id) {
            components.append(Constants.Safeguards.flagLabel)
        }
        if chat.isBlankChat {
            components.append("New chat")
        } else if !createdTimeString.isEmpty {
            components.append("Created \(createdTimeString)")
            if !updatedTimeString.isEmpty {
                components.append(updatedTimeString)
            }
        }
        if isGenerating {
            components.append("Generating response")
        } else if syncFailed {
            components.append("Couldn't sync with cloud")
        } else if isSyncing {
            components.append("Syncing with cloud")
        }
        return components.joined(separator: ", ")
    }

    private var rowAccessibilityTraits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : .isButton
    }

    private var rowAccessibilityHint: String {
        if isEditing || chat.decryptionFailed {
            return ""
        }
        return "Opens the conversation"
    }
}
