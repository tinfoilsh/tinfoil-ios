//
//  ChatSidebar.swift
//  TinfoilChat
//
//  Created on 04/10/25.
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI
import Clerk
import SafariServices

struct ChatSidebar: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(Clerk.self) private var clerk
    @Binding var isOpen: Bool
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject var authManager: AuthManager
    @State private var editingChatId: String? = nil
    @State private var editingTitle: String = ""
    @State private var deletingChatId: String? = nil
    @State private var showSettings: Bool = false
    @State private var showEncryptedChatAlert: Bool = false
    @State private var selectedEncryptedChat: Chat? = nil
    @State private var shouldOpenCloudSync: Bool = false
    
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
    
    var body: some View {
        sidebarContent
            .frame(width: 300)
            .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
            .onReceive(timeUpdateTimer) { _ in
                // Update the current time to trigger view refresh
                currentTime = Date()
            }
            .overlay(
                VStack(spacing: 0) {
                    // Top border
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 1)
                    Spacer()
                }
            )
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity),
                alignment: .trailing
            )
            .alert("Delete Chat", isPresented: .constant(deletingChatId != nil)) {
            Button("Cancel", role: .cancel) {
                deletingChatId = nil
            }
            Button("Delete", role: .destructive) {
                if let id = deletingChatId {
                    viewModel.deleteChat(id)
                    if viewModel.chats.isEmpty {
                        viewModel.createNewChat()
                    }
                }
                deletingChatId = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(shouldOpenCloudSync: shouldOpenCloudSync)
        }
        .alert("Encrypted Chat", isPresented: $showEncryptedChatAlert) {
            Button("Go to Settings") {
                shouldOpenCloudSync = true
                showSettings = true
            }
            Button("Cancel", role: .cancel) {
                selectedEncryptedChat = nil
            }
        } message: {
            Text("This chat is encrypted with a different key. Go to Settings > Cloud Sync to update your encryption key.")
        }
        .onChange(of: showSettings) { _, isShowing in
            // Reset the cloud sync flag when settings closes
            if !isShowing {
                shouldOpenCloudSync = false
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
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
    }
    
    private var sidebarContent: some View {
        VStack(spacing: 0) {
           
            // New Chat Button - shown for all authenticated users
            if authManager.isAuthenticated {
                Button(action: {
                    if !viewModel.messages.isEmpty {
                        viewModel.createNewChat()
                        isOpen = false
                    }
                }) {
                    HStack {
                        Image(systemName: "plus")
                        Text("New chat")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colorScheme == .dark ? Color(hex: "2C2C2E") : Color.white)
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(colorScheme == .dark ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .cornerRadius(8)
                }
                .padding([.horizontal, .top], 16)
            }
            
            // Chat History Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat History")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                if authManager.isAuthenticated {
                    Text("Your chats are encrypted and backed up. You can manage your encryption key in Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Log in to save chat history.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
            
            // Chat List - shows multiple chats for all authenticated users
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(viewModel.chats.enumerated()), id: \.element.id) { index, chat in
                        ChatListItem(
                            chat: chat,
                            isSelected: viewModel.currentChat?.id == chat.id,
                            isEditing: editingChatId == chat.id,
                            editingTitle: $editingTitle,
                            timeString: chat.isBlankChat ? "" : relativeTimeString(from: chat.createdAt),
                            onSelect: {
                                if chat.decryptionFailed {
                                    // Show alert for encrypted chats
                                    selectedEncryptedChat = chat
                                    showEncryptedChatAlert = true
                                } else {
                                    viewModel.selectChat(chat)
                                }
                            },
                            onEdit: { 
                                if editingChatId == chat.id {
                                    // Save the edit
                                    viewModel.updateChatTitle(chat.id, newTitle: editingTitle)
                                    editingChatId = nil
                                } else {
                                    // Start editing
                                    startEditing(chat)
                                }
                            },
                            onDelete: { confirmDelete(chat) },
                            showEditDelete: authManager.isAuthenticated
                        )
                    }
                    
                    // Load More button or loading indicator
                    if viewModel.hasMoreChats {
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
                            Button(action: {
                                Task {
                                    await viewModel.loadMoreChats()
                                }
                            }) {
                                Text("Load More")
                                    .foregroundColor(.primary)
                                    .font(.system(size: 16, weight: .regular))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(UIColor.secondarySystemBackground).opacity(0.3))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.gray.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .refreshable {
                if authManager.isAuthenticated {
                    // Create a continuation to properly handle the async operation
                    await withCheckedContinuation { continuation in
                        Task.detached {
                            await viewModel.performFullSync()
                            continuation.resume()
                        }
                    }
                }
            }
            
            Divider()
                .background(Color.gray.opacity(0.3))
                .padding(.bottom, 8)
            
            // Settings Button
            Button(action: {
                showSettings = true
            }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .center)
                .background(colorScheme == .dark ? Color(hex: "2C2C2E") : Color.white)
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(colorScheme == .dark ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
    
    private func startEditing(_ chat: Chat) {
        editingChatId = chat.id
        editingTitle = chat.title
    }
    
    private func confirmDelete(_ chat: Chat) {
        deletingChatId = chat.id
    }
}

struct ChatListItem: View {
    let chat: Chat
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingTitle: String
    let timeString: String
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
                        
                        // Save and Cancel buttons for editing mode
                        HStack(spacing: 12) {
                            Button(action: onEdit) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.primary)
                            }
                            Button(action: { editingTitle = chat.title; onEdit() }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(.primary)
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            if chat.decryptionFailed {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            Text(chat.decryptionFailed ? "Encrypted" : chat.title)
                                .foregroundColor(chat.decryptionFailed ? .orange : .primary)
                                .lineLimit(1)
                            
                            if chat.isBlankChat {
                                // Blue dot indicator for new chats
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
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
                
                // Timestamp or decryption failure message inside the cell
                if !isEditing {
                    if chat.decryptionFailed {
                        Text("Failed to decrypt: wrong key")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if !timeString.isEmpty {
                        Text(timeString)
                            .font(.caption)
                            .foregroundColor(.gray)
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
    }
}

