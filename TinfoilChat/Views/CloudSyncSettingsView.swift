//
//  CloudSyncSettingsView.swift
//  TinfoilChat
//
//  Settings view for managing cloud sync and encryption
//

import SwiftUI

struct CloudSyncSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var authManager: AuthManager
    
    @State private var showKeyInput: Bool = false
    @State private var newKeyInput: String = ""
    @State private var keyError: String? = nil
    @State private var showKeyConfirmation: Bool = false
    @State private var isProcessing: Bool = false
    @State private var copiedToClipboard: Bool = false
    
    var body: some View {
        NavigationStack {
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
                        } else {
                            Text("Synced")
                                .foregroundColor(.accentPrimary)
                        }
                    }
                    
                    if let lastSync = viewModel.lastSyncDate {
                        HStack {
                            Text("Last Sync")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(lastSync, style: .relative)
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
                    }
                    .disabled(viewModel.isSyncing || !authManager.isAuthenticated)
                } header: {
                    Text("Synchronization")
                }
                
                // Encryption Key Section
                Section {
                    if let key = viewModel.encryptionKey {
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
                                        .foregroundColor(copiedToClipboard ? .accentPrimary : .primary)
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
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    Text("Your encryption key is used to secure all your chat data. Keep it safe and never share it with anyone.")
                        .font(.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.backgroundPrimary : Color(UIColor.systemGroupedBackground))
            .navigationTitle("Cloud Sync Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.accentPrimary)
                }
            }
            .sheet(isPresented: $showKeyInput) {
                NavigationView {
                    VStack(spacing: 20) {
                        Text("Change Encryption Key")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        TextField("Enter new encryption key", text: $newKeyInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                        
                        if let error = keyError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showKeyInput = false
                                newKeyInput = ""
                                keyError = nil
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                            
                            Button("Change Key") {
                                changeEncryptionKey()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(newKeyInput.isEmpty ? Color.gray : Color.accentPrimary)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .disabled(newKeyInput.isEmpty || isProcessing)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .navigationBarHidden(true)
                }
                .interactiveDismissDisabled(isProcessing)
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
    
    private func changeEncryptionKey() {
        let keyToSet = newKeyInput
        
        // Dismiss modal immediately for better UX
        showKeyInput = false
        newKeyInput = ""
        
        // Process key change and decryption in background
        Task {
            await viewModel.setEncryptionKey(keyToSet)
        }
    }
}