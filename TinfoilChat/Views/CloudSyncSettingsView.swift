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
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var passkeyManager = PasskeyManager.shared
    @ObservedObject private var syncHealth = SyncHealthStore.shared

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
    
    @State private var copiedToClipboard: Bool = false
    @State private var showBackupKeySheet: Bool = false
    @State private var passkeyBundles: [EnclaveKeyCurrentBundle] = []
    @State private var removingPasskeyId: String? = nil
    @State private var passkeyBundleError: String? = nil
    
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

                    syncHealthRows

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
                    }
            } header: {
                Text("Encryption")
            } footer: {
                    Text(passkeyManager.passkeyActive
                         ? "Your passkey secures cloud sync on this device. Reveal the backup key only if you want a copy."
                         : "This key secures your cloud sync. Keep a copy somewhere safe.")
                        .font(.caption)
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
            } // end if settings.isCloudSyncEnabled

            passkeySection

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
        .task(id: [settings.isCloudSyncEnabled, passkeyManager.passkeyActive]) {
            await refreshPasskeyBundles()
        }
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
            .sheet(isPresented: $showBackupKeySheet) {
                BackupEncryptionKeySheet()
            }
    }
    
    /// Gate-driven status rows from the sync-health store: explains
    /// why sync is blocked, offers the recovery wizard for key
    /// problems, and counts chats stuck on terminal upload failures.
    @ViewBuilder
    private var syncHealthRows: some View {
        switch syncHealth.gate {
        case .actionRequired(let reason, _):
            VStack(alignment: .leading, spacing: 8) {
                Label(actionRequiredMessage(for: reason), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(reason == .accountBlocked ? .red : .orange)
                if reason != .accountBlocked {
                    Button {
                        viewModel.cloudSyncOnboardingMode = .recovery
                        viewModel.showCloudSyncOnboarding = true
                    } label: {
                        Text("Recover Key")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .paused(let reason, _):
            Label(
                reason == .attestation
                    ? "The sync server couldn't be verified. Retrying automatically."
                    : "Having trouble reaching the cloud. Retrying automatically.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundColor(.orange)
        case .ok:
            EmptyView()
        }

        if !syncHealth.failedChats.isEmpty {
            Text(
                syncHealth.failedChats.count == 1
                    ? "1 chat couldn't be synced. It's marked in the sidebar."
                    : "\(syncHealth.failedChats.count) chats couldn't be synced. They're marked in the sidebar."
            )
            .font(.caption)
            .foregroundColor(.orange)
        }
    }

    private func actionRequiredMessage(for reason: SyncHealthStore.ActionReason) -> String {
        switch reason {
        case .keyRecovery:
            return "Sync is paused because your encryption key needs to be recovered."
        case .keyMismatch:
            return "This device's encryption key is out of date and needs to be recovered."
        case .keyConflict:
            return "Your cloud data is protected by a different key than this device's."
        case .accountBlocked:
            return "Sync is unavailable for this account. Please contact support if this persists."
        }
    }

    @ViewBuilder
    private var passkeySection: some View {
        if passkeyManager.passkeyActive
            || !passkeyBundles.isEmpty
            || passkeyBundleError != nil
            || passkeyManager.passkeyAddDeviceAvailable
            || passkeyManager.passkeySetupAvailable
            || passkeyManager.recoverySkipped {
            Section {
                if passkeyManager.passkeyActive {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.key.fill")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text("Sync and backup using Passkeys")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        Text("Use Face ID or Touch ID to sync chats across devices")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text("Passkey active")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }

                if !passkeyBundles.isEmpty || passkeyBundleError != nil {
                    passkeyBundleInventory
                }

                if passkeyManager.passkeyAddDeviceAvailable && EncryptionService.shared.hasEncryptionKey() {
                    passkeyActionButton(
                        title: "Set Up Passkey on This Device",
                        subtitle: "Your other devices use a passkey already. Add one here for one-tap access."
                    ) {
                        await passkeyManager.createPasskeyBackup()
                    }
                } else if passkeyManager.passkeySetupAvailable && EncryptionService.shared.hasEncryptionKey() {
                    passkeyActionButton(
                        title: "Add Passkey for seamless sync",
                        subtitle: "Use Face ID or Touch ID to sync chats across devices"
                    ) {
                        await passkeyManager.createPasskeyBackup()
                    }
                } else if passkeyManager.passkeySetupAvailable && !EncryptionService.shared.hasEncryptionKey() {
                    passkeyActionButton(
                        title: "Add Passkey for seamless sync",
                        subtitle: "Create a passkey to sync chats across devices"
                    ) {
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
                } else if passkeyManager.recoverySkipped && !EncryptionService.shared.hasEncryptionKey() {
                    passkeyActionButton(
                        title: "Unlock Cloud Sync",
                        subtitle: "Use your passkey to unlock and resume syncing chats across devices."
                    ) {
                        await MainActor.run { dismiss() }
                        await viewModel.reattemptPasskeyRecovery()
                    }
                }
            } header: {
                Text("Passkeys")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
    }

    private func passkeyActionButton(
        title: String,
        subtitle: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button(action: {
            Task {
                await action()
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var passkeyBundleInventory: some View {
        let localCredentialId = UserDefaults.standard.string(
            forKey: Constants.StorageKeys.Secret.passkeyEnclaveCredentialId
        )
        let sorted = passkeyBundles.sorted { a, b in
            if a.credentialId == localCredentialId { return true }
            if b.credentialId == localCredentialId { return false }
            return (a.createdAt ?? "") > (b.createdAt ?? "")
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Registered platforms (\(sorted.count))")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            ForEach(sorted, id: \.credentialId) { bundle in
                passkeyBundleRow(
                    bundle: bundle,
                    isCurrentPlatform: bundle.credentialId == localCredentialId
                )
            }
            if let passkeyBundleError {
                Text(passkeyBundleError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func passkeyBundleRow(
        bundle: EnclaveKeyCurrentBundle,
        isCurrentPlatform: Bool
    ) -> some View {
        let credLabel = bundle.credentialId.count <= 12
            ? bundle.credentialId
            : "\(bundle.credentialId.prefix(6))…\(bundle.credentialId.suffix(4))"
        let dateLabel: String
        if let created = bundle.createdAt, !created.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: created)
                ?? ISO8601DateFormatter().date(from: created)
            if let date {
                let display = DateFormatter()
                display.dateStyle = .medium
                dateLabel = display.string(from: date)
            } else {
                dateLabel = "Date unknown"
            }
        } else {
            dateLabel = "Date unknown"
        }
        let isRemoving = removingPasskeyId == bundle.credentialId
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(isCurrentPlatform ? "This platform" : "Other platform")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                Text("\(credLabel) · \(dateLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: {
                Task { await removeBundle(bundle.credentialId) }
            }) {
                Text(isRemoving ? "Removing…" : "Remove")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(isRemoving ? .secondary : .red)
            }
            .disabled(removingPasskeyId != nil)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func refreshPasskeyBundles() async {
        guard settings.isCloudSyncEnabled else {
            passkeyBundles = []
            passkeyBundleError = nil
            return
        }
        do {
            passkeyBundles = try await passkeyManager.listPasskeyBundles()
            passkeyBundleError = nil
        } catch {
            // Keep the previous inventory: clearing it would make a
            // load failure indistinguishable from "no passkeys
            // registered" for a security-relevant list.
            passkeyBundleError = "Couldn't load registered passkeys. Please try again later."
        }
    }

    private func removeBundle(_ credentialId: String) async {
        // One removal at a time: the in-flight UI state is single-valued
        // and concurrent deletes would race it and duplicate requests.
        guard removingPasskeyId == nil else { return }
        removingPasskeyId = credentialId
        defer { removingPasskeyId = nil }
        do {
            try await passkeyManager.removePasskeyBundle(credentialId: credentialId)
            await refreshPasskeyBundles()
        } catch {
            passkeyBundleError = "Couldn't remove the passkey. Please try again."
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
