//
//  ChatSidebar.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import ClerkKit
import SafariServices

func isRootSidebarChat(_ chat: Chat) -> Bool {
    !chat.isTemporary && chat.projectId == nil && !chat.decryptionFailed
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
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject var authManager: AuthManager
    @State private var editingChatId: String? = nil
    @State private var editingTitle: String = ""
    @State private var deletingChatId: String? = nil
    @State private var showDeleteAlert: Bool = false

    @State private var isTabSwitching: Bool = false
    @State private var isProjectsExpanded: Bool = false
    @State private var isChatsExpanded: Bool = true
    @State private var chatSearchTerm: String = ""
    @StateObject private var chatSearch = ChatSearchController()
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var cloudSync = CloudSyncService.shared
    @ObservedObject private var syncHealth = SyncHealthStore.shared

    private var activeTab: ChatStorageTab {
        viewModel.activeStorageTab
    }

    private var filteredChats: [Chat] {
        let source: [Chat]
        if authManager.isAuthenticated && settings.isCloudSyncEnabled {
            switch activeTab {
            case .cloud:
                source = viewModel.chats
            case .local:
                source = viewModel.localChats
            }
        } else {
            // When cloud sync is off, all chats are local
            source = viewModel.localChats
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

    private var searchResultChats: [Chat] {
        guard isChatSearchActive else { return [] }
        // Enclave unavailable (older deploy, no eligible key): degrade
        // to filtering the locally loaded titles so the box still does
        // something useful.
        guard chatSearch.available else {
            let needle = chatSearchTerm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return filteredChats.filter {
                !$0.isBlankChat && $0.title.lowercased().contains(needle)
            }
        }
        // The index covers every synced chat, so results can include
        // project chats; apply the same root-list exclusions so search
        // never surfaces rows this list would not show.
        return chatSearch.results.filter(isRootSidebarChat)
    }

    private var displayedChats: [Chat] {
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
    private func updatedTimeString(for chat: Chat) -> String {
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
        VStack(spacing: 0) {
            recoveryBanner
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if authManager.isAuthenticated && settings.isCloudSyncEnabled {
                        projectsSection
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                    }

                    chatsSectionHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if isTabSwitching {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if isChatsExpanded {
                        if authManager.isAuthenticated && settings.isCloudSyncEnabled && settings.isLocalOnlyModeEnabled {
                            cloudLocalTabSwitcher
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }

                        chatsDescription
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        if isChatSearchEnabled {
                            chatSearchField
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }

                        chatList
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }
            }
            .applyAlwaysBounceIfAvailable()
            .refreshable {
                await authManager.initializeAuthState()
                await viewModel.performFullSync()
            }
            .frame(maxHeight: .infinity)

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

    private var chatList: some View {
        VStack(spacing: 12) {
            ForEach(Array(displayedChats.enumerated()), id: \.element.id) { _, chat in
                ChatListItem(
                    chat: chat,
                    isSelected: viewModel.currentChat?.id == chat.id,
                    isEditing: editingChatId == chat.id,
                    editingTitle: $editingTitle,
                    createdTimeString: chat.isBlankChat ? "" : relativeTimeString(from: chat.createdAt),
                    updatedTimeString: chat.isBlankChat ? "" : updatedTimeString(for: chat),
                    isSyncing: !chat.isBlankChat && cloudSync.pendingUploadChatIds.contains(chat.id),
                    syncFailed: !chat.isBlankChat && syncHealth.failedChats[chat.id] != nil,
                    isGenerating: viewModel.isChatStreaming(chat.id),
                    onSelect: {
                        viewModel.selectChat(chat)
                    },
                    onEdit: {
                        if editingChatId == chat.id {
                            viewModel.updateChatTitle(chat.id, newTitle: editingTitle)
                            editingChatId = nil
                        } else {
                            startEditing(chat)
                        }
                    },
                    onDelete: { confirmDelete(chat) },
                    showEditDelete: authManager.isAuthenticated
                )
                .contextMenu {
                    if authManager.isAuthenticated && !chat.isBlankChat && !chat.decryptionFailed {
                        ForEach(viewModel.projects.filter { $0.decryptionFailed != true }) { project in
                            Button {
                                Task {
                                    await viewModel.moveChatToProject(chatId: chat.id, projectId: project.id)
                                }
                            } label: {
                                Label("Add to \(project.name)", systemImage: "folder")
                            }
                        }
                    }
                }
            }

            if isChatSearchActive {
                chatSearchStatusRow
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
                } else {
                    loadMoreButton
                }
            }
        }
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
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Cloud sync needs attention")
                }
            }
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
                            Image(systemName: project.decryptionFailed == true ? "lock.fill" : "folder")
                                .foregroundColor(project.decryptionFailed == true ? .orange : .accentColor)
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

    private func startEditing(_ chat: Chat) {
        editingChatId = chat.id
        editingTitle = chat.title
    }
    
    private func confirmDelete(_ chat: Chat) {
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
}

struct ChatListItem: View {
    let chat: Chat
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingTitle: String
    let createdTimeString: String
    let updatedTimeString: String
    var isSyncing: Bool = false
    var syncFailed: Bool = false
    var isGenerating: Bool = false
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
                            Text(chat.title)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
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
