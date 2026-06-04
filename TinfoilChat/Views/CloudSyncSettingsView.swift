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
    @ObservedObject private var passkeyManager = PasskeyManager.shared

    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { settings.isCloudSyncEnabled },
            set: { newValue in
                if newValue {
                    if EncryptionService.shared.hasEncryptionKey() {
                        settings.isCloudSyncEnabled = true
                        viewModel.reloadEncryptionKey()
                        Task { await viewModel.performFullSync() }
                    } else {
                        Task {
                            let result = await passkeyManager.retryPasskeySetup()
                            switch result {
                            case .manualSetupRequired:
                                await MainActor.run {
                                    viewModel.cloudSyncOnboardingMode = .setup
                                    viewModel.showCloudSyncOnboarding = true
                                }
                            case .manualRecoveryRequired:
                                await MainActor.run {
                                    viewModel.cloudSyncOnboardingMode = .recovery
                                    viewModel.showCloudSyncOnboarding = true
                                }
                            default:
                                break
                            }
                        }
                    }
                } else {
                    settings.isCloudSyncEnabled = false
                    viewModel.activeStorageTab = .local
                    Task { await viewModel.deleteNonLocalChats() }
                }
            }
        )
    }
    
    @State private var showKeyInput: Bool = false
    @State private var showReplacePrimaryOptions: Bool = false
    @State private var keyInputMode: KeyInputMode = .replacePrimary
    @State private var replacePrimaryMode: CloudKeyActivationMode = .recoverExisting
    @State private var copiedToClipboard: Bool = false
    @State private var showBackupKeySheet: Bool = false
    
    var body: some View {
        List {
            Section {
                Toggle("Cloud Sync", isOn: cloudSyncBinding)
                    .tint(Color.accentPrimary)
            } footer: {
                Text("Encrypt and back up your chats so they sync across devices.")
                    .font(.caption)
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            // Sync Status Section
            if settings.isCloudSyncEnabled {
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
                                .accessibilityLabel(copiedToClipboard ? "Key copied" : "Copy key")
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                    
                    if passkeyManager.passkeyActive {
                        Button(action: {
                            showBackupKeySheet = true
                        }) {
                            Label("Reveal Backup Key", systemImage: "key.viewfinder")
                                .foregroundColor(.primary)
                        }

                        Button(action: {
                            keyInputMode = .addRecovery
                            showKeyInput = true
                        }) {
                            Label("Add Decryption Key", systemImage: "key.badge.plus")
                                .foregroundColor(.primary)
                        }
                    } else {
                        Button(action: {
                            showReplacePrimaryOptions = true
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
                    }
            } header: {
                Text("Encryption")
            } footer: {
                    Text(passkeyManager.passkeyActive
                         ? "Add an older key to decrypt data from before a key rotation. Your passkey manages the primary key."
                         : "Recovery keys can decrypt older data without changing your current primary key. Use Recover Existing to verify a replacement key against your cloud data, or Start Fresh to only use it for future uploads on this device.")
                        .font(.caption)
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
            } // end if settings.isCloudSyncEnabled

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
        .alert("Replace Primary Key", isPresented: $showReplacePrimaryOptions) {
            Button("Recover Existing Data") {
                replacePrimaryMode = .recoverExisting
                keyInputMode = .replacePrimary
                DispatchQueue.main.async {
                    showKeyInput = true
                }
            }
            Button("Start Fresh") {
                replacePrimaryMode = .explicitStartFresh
                keyInputMode = .replacePrimary
                DispatchQueue.main.async {
                    showKeyInput = true
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose how this key should behave. Recover Existing verifies it against your existing cloud data. Start Fresh only uses it for future cloud writes on this device.")
        }
            .sheet(isPresented: $showKeyInput) {
                EncryptionKeyInputView(
                    isPresented: $showKeyInput,
                    title: keyInputTitle,
                    description: keyInputDescription,
                    submitLabel: keyInputSubmitLabel
                ) { importedKey in
                    do {
                        if keyInputMode == .addRecovery {
                            try await viewModel.addRecoveryKey(importedKey)
                        } else {
                            try await viewModel.setEncryptionKey(importedKey, mode: replacePrimaryMode)
                        }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: $showBackupKeySheet) {
                BackupEncryptionKeySheet()
            }
    }
    
    private func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return key }
        let visibleChars = 12 // Show first 12 characters
        let prefix = String(key.prefix(visibleChars))
        let masked = String(repeating: "•", count: key.count - visibleChars)
        return "\(prefix)\(masked)"
    }

    private var keyInputTitle: String {
        switch keyInputMode {
        case .addRecovery:
            return passkeyManager.passkeyActive ? "Add Decryption Key" : "Add Recovery Key"
        case .replacePrimary:
            return replacePrimaryMode == .recoverExisting
                ? "Recover Existing Key"
                : "Start Fresh with New Primary"
        }
    }

    private var keyInputDescription: String {
        switch keyInputMode {
        case .addRecovery:
            return passkeyManager.passkeyActive
                ? "Add an older key to decrypt data from before a key rotation. Your passkey manages the primary key."
                : "Add a fallback key that can decrypt older cloud data without changing your current primary key."
        case .replacePrimary:
            return replacePrimaryMode == .recoverExisting
                ? "Verify this key against your existing cloud data before future cloud writes resume on this device."
                : "Use this key for future cloud writes on this device without validating it against older cloud data."
        }
    }

    private var keyInputSubmitLabel: String {
        switch keyInputMode {
        case .addRecovery:
            return passkeyManager.passkeyActive ? "Add Key" : "Add Recovery Key"
        case .replacePrimary:
            return replacePrimaryMode == .recoverExisting
                ? "Recover Existing Data"
                : "Start Fresh"
        }
    }
}

/// Sheet that reveals the current encryption key as a backup. Shown only when
/// the user has an active passkey, since their passkey already wraps the key
/// and they don't need to handle a copy day-to-day.
private struct BackupEncryptionKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isCopied: Bool = false
    @State private var showFullKey: Bool = false

    private var key: String? {
        EncryptionService.shared.getKey()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }
                .padding(.top, 24)

                Text("Backup Encryption Key")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Your passkey already secures cloud sync on this device. Save a copy of this key only if you want a paper backup or need to sign in on a device without your passkey.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let key {
                    VStack(spacing: 12) {
                        Text(showFullKey ? key : maskedKey(key))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                            .textSelection(.enabled)
                            .animation(nil, value: showFullKey)

                        HStack(spacing: 12) {
                            Button(action: {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    showFullKey.toggle()
                                }
                            }) {
                                Label(showFullKey ? "Hide" : "Reveal", systemImage: showFullKey ? "eye.slash" : "eye")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(UIColor.tertiarySystemBackground))
                                    .cornerRadius(10)
                            }

                            Button(action: { copyKey(key) }) {
                                Label(isCopied ? "Copied" : "Copy",
                                      systemImage: isCopied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(isCopied ? Color.green.opacity(0.2) : Color(UIColor.tertiarySystemBackground))
                                    .cornerRadius(10)
                            }
                        }
                        .foregroundColor(.primary)
                    }
                    .padding(.horizontal)
                } else {
                    Text("No encryption key found on this device.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 16 else { return key }
        let prefix = String(key.prefix(8))
        let suffix = String(key.suffix(8))
        return "\(prefix)…\(suffix)"
    }

    private func copyKey(_ key: String) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: key]],
            options: [
                .expirationDate: Date().addingTimeInterval(Constants.CloudSync.clipboardExpirationSeconds)
            ]
        )
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}
