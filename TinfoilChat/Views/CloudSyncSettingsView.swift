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
    @State private var copiedToClipboard: Bool = false
    @State private var isKeyVisible: Bool = false
    @FocusState private var isKeyFieldFocused: Bool
    
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
                                .foregroundColor(.adaptiveAccent)
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
                            .foregroundColor(.adaptiveAccent)
                    }
                    .disabled(viewModel.isSyncing || !authManager.isAuthenticated)
                } header: {
                    Text("Synchronization")
                }
                
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
                            .foregroundColor(.adaptiveAccent)
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
            .sheet(isPresented: $showKeyInput) {
                NavigationView {
                    VStack(spacing: 20) {
                        HStack {
                            if isKeyVisible {
                                TextField("Enter new encryption key (key_...)", text: $newKeyInput)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .font(.system(.body, design: .monospaced))
                                    .focused($isKeyFieldFocused)
                                    .onChange(of: newKeyInput) { _, newValue in
                                        validateKey(newValue)
                                    }
                            } else {
                                SecureField("Enter new encryption key (key_...)", text: $newKeyInput)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .font(.system(.body, design: .monospaced))
                                    .focused($isKeyFieldFocused)
                                    .onChange(of: newKeyInput) { _, newValue in
                                        validateKey(newValue)
                                    }
                            }
                            
                            Button(action: {
                                isKeyVisible.toggle()
                            }) {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let error = keyError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        Button("Change Key") {
                            if keyError == nil {
                                changeEncryptionKey()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(newKeyInput.isEmpty || keyError != nil ? Color.gray : Color.accentPrimary)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .disabled(newKeyInput.isEmpty || keyError != nil)
                        
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Change Encryption Key")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarItems(
                        leading: Button("Cancel") {
                            showKeyInput = false
                            newKeyInput = ""
                            keyError = nil
                        }
                    )
                    .onAppear {
                        // Automatically focus the text field and show keyboard
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isKeyFieldFocused = true
                        }
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
    
    private func validateKey(_ key: String) {
        // Reset error first
        keyError = nil
        
        // Check if key is empty (this is handled by button disable state, but good to be explicit)
        if key.isEmpty {
            return
        }
        
        // Check if key has the required prefix
        if !key.hasPrefix("key_") {
            keyError = "Key must start with 'key_' prefix"
            return
        }
        
        // Validate key characters (after prefix)
        let keyWithoutPrefix = String(key.dropFirst(4))
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if keyWithoutPrefix.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
            keyError = "Key must only contain lowercase letters and numbers after the prefix"
            return
        }
        
        // Validate key length
        if keyWithoutPrefix.count % 2 != 0 {
            keyError = "Invalid key length"
            return
        }
    }
    
    private func changeEncryptionKey() {
        let keyToSet = newKeyInput
        
        // Validate one more time before proceeding
        validateKey(keyToSet)
        if keyError != nil {
            return
        }
        
        // Dismiss modal immediately for better UX
        showKeyInput = false
        newKeyInput = ""
        keyError = nil
        
        // Process key change and decryption in background
        Task {
            await viewModel.setEncryptionKey(keyToSet)
        }
    }
}