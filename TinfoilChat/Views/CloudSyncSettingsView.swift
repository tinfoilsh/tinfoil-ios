//
//  CloudSyncSettingsView.swift
//  TinfoilChat
//
//  Settings view for managing cloud sync and encryption
//

import SwiftUI
import AVFoundation

struct CloudSyncSettingsView: View {
    private enum KeyInputMode {
        case replacePrimary
        case addRecovery
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var authManager: AuthManager
    @ObservedObject private var settings = SettingsManager.shared
    
    @State private var showKeyInput: Bool = false
    @State private var keyInputMode: KeyInputMode = .replacePrimary
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

                    if settings.isCloudSyncEnabled &&
                        CloudKeyAuthorizationStore.shared.currentMode() == nil {
                        Text("Cloud sync writes are paused until this device verifies the current encryption key.")
                            .font(.caption)
                            .foregroundColor(.orange)
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
                        keyInputMode = .replacePrimary
                        showKeyInput = true
                    }) {
                        Label("Replace Primary Key", systemImage: "key.fill")
                            .foregroundColor(.primary)
                    }

                    Button(action: {
                        keyInputMode = .addRecovery
                        showKeyInput = true
                    }) {
                        Label("Add Recovery Key", systemImage: "key.badge.plus")
                            .foregroundColor(.primary)
                    }
            } header: {
                Text("Encryption")
            } footer: {
                    Text("Recovery keys can decrypt older data without changing your current primary key. Replacing the primary key starts a new encrypted cloud history for future uploads.")
                        .font(.caption)
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            // Local-Only Mode Section
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable local chats", isOn: Binding(
                        get: { settings.isLocalOnlyModeEnabled },
                        set: { newValue in
                            settings.isLocalOnlyModeEnabled = newValue
                            if !newValue {
                                viewModel.switchStorageTab(to: .cloud)
                            }
                        }
                    ))
                    .tint(Color.accentPrimary)
                    if settings.isLocalOnlyModeEnabled {
                        Text("Local chats will be permanently erased when you sign out. Treat local chats as temporary.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Local Chats")
            } footer: {
                Text("Enable to create chats that stay only on this device and are never synced to the cloud.")
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
                EncryptionKeyInputView(
                    isPresented: $showKeyInput,
                    title: keyInputMode == .addRecovery ? "Add Recovery Key" : "Replace Primary Key",
                    description: keyInputMode == .addRecovery
                        ? "Add a fallback key that can decrypt older cloud data without changing your current primary key."
                        : "Replacing the primary key will use this key for future cloud writes on this device.",
                    submitLabel: keyInputMode == .addRecovery ? "Add Recovery Key" : "Replace Primary Key"
                ) { importedKey in
                    do {
                        if keyInputMode == .addRecovery {
                            try await viewModel.addRecoveryKey(importedKey)
                        } else {
                            try await viewModel.setEncryptionKey(importedKey, mode: .explicitStartFresh)
                        }
                        return nil
                    } catch {
                        return error.localizedDescription
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
