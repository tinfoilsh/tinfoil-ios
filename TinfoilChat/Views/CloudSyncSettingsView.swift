//
//  CloudSyncSettingsView.swift
//  TinfoilChat
//
//  Settings view for managing cloud sync and encryption
//

import SwiftUI
import AVFoundation

struct CloudSyncSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var authManager: AuthManager
    
    @State private var showKeyInput: Bool = false
    @State private var copiedToClipboard: Bool = false
    
    var body: some View {
        List {
            // Sync Status Section
            Section {
                    HStack {
                        Text("Sync Status")
                        Spacer()
                        if viewModel.isSyncing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if !viewModel.syncErrors.isEmpty {
                            Text("Error")
                                .foregroundColor(.red)
                        } else if viewModel.lastSyncDate != nil {
                            Text("Synced")
                                .foregroundColor(.green)
                        } else {
                            Text("Not synced")
                                .foregroundColor(.gray)
                        }
                    }
                    
                    HStack {
                        Text("Last Sync")
                            .foregroundColor(.secondary)
                        Spacer()
                        if let lastSync = viewModel.lastSyncDate {
                            Text(lastSync, style: .relative)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Never")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if !viewModel.syncErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sync Errors:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(viewModel.syncErrors, id: \.self) { error in
                                Text("• \(error)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await viewModel.performFullSync()
                        }
                    }) {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                            .foregroundColor(.primary)
                    }
                    .disabled(viewModel.isSyncing || !authManager.isAuthenticated)
                } header: {
                    Text("Synchronization")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
            
            // Encryption Key Section
            Section {
                    if let key = viewModel.getCurrentEncryptionKey() {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current Key")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Text(maskKey(key))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Button(action: {
                                    UIPasteboard.general.string = key
                                    copiedToClipboard = true
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        copiedToClipboard = false
                                    }
                                }) {
                                    Image(systemName: copiedToClipboard ? "checkmark.circle.fill" : "doc.on.doc")
                                        .foregroundColor(copiedToClipboard ? .adaptiveAccent : .primary)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                    
                    Button(action: {
                        showKeyInput = true
                    }) {
                        Label("Change Encryption Key", systemImage: "key.fill")
                            .foregroundColor(.primary)
                    }
            } header: {
                Text("Encryption")
            } footer: {
                    Text("Your encryption key is used to secure all your chat data. Keep it safe and never share it with anyone.")
                        .font(.caption)
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Cloud Sync Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Reset navigation bar to use system colors for settings screens
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance

            // Kick off a quick sync so Last Sync is fresh when opening this screen
            Task {
                await viewModel.performFullSync()
            }
        }
        .onDisappear {
            // Restore dark navigation bar for main views
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Color.backgroundPrimary)
            appearance.shadowColor = .clear
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
            .sheet(isPresented: $showKeyInput) {
                EncryptionKeyInputView(isPresented: $showKeyInput) { importedKey in
                    Task {
                        do {
                            try await viewModel.setEncryptionKey(importedKey)
                        } catch {
                            #if DEBUG
                            print("Failed to change encryption key: \(error)")
                            #endif
                        }
                    }
                }
            }
    }
    
    private func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return key }
        let visibleChars = 12 // Show first 12 characters
        let prefix = String(key.prefix(visibleChars))
        let masked = String(repeating: "•", count: key.count - visibleChars)
        return "\(prefix)\(masked)"
    }
}
