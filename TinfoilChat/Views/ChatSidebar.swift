//
//  ChatSidebar.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

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
    @State private var showSignUpOrSignIn: Bool = false
    @State private var showSettings: Bool = false
    
    var body: some View {
        sidebarContent
            .frame(width: 300)
            .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
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
        .sheet(isPresented: $showSignUpOrSignIn) {
            AuthenticationView()
                .environmentObject(authManager)
                .onDisappear {
                    // Refresh the UI when the auth view is dismissed
                    if authManager.isAuthenticated {
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
                    Text("Your chat history is stored locally.")
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
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.chats) { chat in
                        ChatListItem(
                            chat: chat,
                            isSelected: viewModel.currentChat?.id == chat.id,
                            isEditing: editingChatId == chat.id,
                            editingTitle: $editingTitle,
                            onSelect: {
                                viewModel.selectChat(chat)
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
                }
                .padding(.horizontal, 16)
            }
            
            Spacer()
            
            Divider()
                .background(Color.gray.opacity(0.3))
                .padding(.vertical, 8)
            
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
            .padding(.bottom, 8)
            
            // Account section
            if authManager.isAuthenticated {
                accountView
            } else {
                // Sign up or Log In Button when not authenticated
                Button(action: {
                    showSignUpOrSignIn = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                        Text("Sign up or Log In")
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
                .padding(.bottom, 8)
            }
        }
    }
    
    private var accountView: some View {
        VStack(spacing: 8) {
            // Account button to open the full authentication view
            Button(action: {
                showSignUpOrSignIn = true
            }) {
                HStack {
                    // Display user info if available
                    if let user = clerk.user {
                        if !user.imageUrl.isEmpty {
                            AsyncImage(url: URL(string: user.imageUrl)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "person.circle.fill")
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .resizable()
                                .frame(width: 28, height: 28)
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                        }
                        
                        Text("\(user.firstName ?? "") \(user.lastName ?? "")")
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                        
                        Spacer()
                    }
                    // If user is not in clerk but in local storage
                    else if let userData = authManager.localUserData {
                        if let imageUrlString = userData["imageUrl"] as? String, 
                           !imageUrlString.isEmpty,
                           let url = URL(string: imageUrlString) {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "person.circle.fill")
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .resizable()
                                .frame(width: 28, height: 28)
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                        }
                        
                        Text((userData["name"] as? String) ?? "Account")
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                        
                        Spacer()
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 28, height: 28)
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                        
                        Text("Account")
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                        
                        Spacer()
                    }
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colorScheme == .dark ? Color(hex: "2C2C2E") : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(colorScheme == .dark ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
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
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let showEditDelete: Bool
    
    var body: some View {
        Button(action: onSelect) {
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
                    Text(chat.title)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if isSelected && showEditDelete {
                        // Edit and Delete buttons
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
            .padding()
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(isSelected ? Color(UIColor.secondarySystemBackground) : Color.clear)
        .cornerRadius(8)
    }
}

