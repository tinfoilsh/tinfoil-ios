//
//  EncryptionKeySetupView.swift
//  TinfoilChat
//
//  View for setting up encryption key for first-time users
//

import SwiftUI

struct EncryptionKeySetupView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ChatViewModel
    
    @State private var keyInput: String = ""
    @State private var showGeneratedKey: Bool = false
    @State private var generatedKey: String = ""
    @State private var keyError: String? = nil
    @State private var isProcessing: Bool = false
    @State private var copiedToClipboard: Bool = false
    @FocusState private var isKeyInputFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    
                    Text("Secure Your Chats")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Your chats are end-to-end encrypted. Set up your encryption key to get started.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 32)
                
                // Options
                VStack(spacing: 16) {
                    // Generate New Key Option
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Generate New Key", systemImage: "key.fill")
                            .font(.headline)
                        
                        Text("Create a new encryption key for this device")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if showGeneratedKey {
                            VStack(spacing: 8) {
                                HStack {
                                    Text(generatedKey)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                    
                                    Button(action: {
                                        let pasteboard = UIPasteboard.general
                                        pasteboard.setItems([[UIPasteboard.typeAutomatic: generatedKey]], 
                                                          options: [.expirationDate: Date().addingTimeInterval(60)])
                                        copiedToClipboard = true
                                        
                                        // Reset after 2 seconds
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            copiedToClipboard = false
                                        }
                                    }) {
                                        Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                
                                Text("⚠️ Save this key securely! You'll need it to access your chats on other devices.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        Button(action: generateNewKey) {
                            Text(showGeneratedKey ? "Use This Key" : "Generate New Key")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(isProcessing)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    
                    // Divider
                    HStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 1)
                        Text("OR")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 1)
                    }
                    
                    // Import Existing Key Option
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Import Existing Key", systemImage: "square.and.arrow.down")
                            .font(.headline)
                        
                        Text("Use a key from another device")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextField("Enter your encryption key (key_...)", text: $keyInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                            .focused($isKeyInputFocused)
                        
                        if let error = keyError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        Button(action: importExistingKey) {
                            Text("Import Key")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(keyInput.isEmpty ? Color.gray : Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(keyInput.isEmpty || isProcessing)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Info Footer
                VStack(spacing: 4) {
                    Label("Your encryption key never leaves your device", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label("We cannot recover your chats if you lose your key", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom)
            }
            .navigationBarTitle("", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Skip") {
                        // Allow skipping for now, but generate a key in the background
                        Task { @MainActor in
                            do {
                                let key = EncryptionService.shared.generateKey()
                                try await viewModel.setEncryptionKey(key)
                                dismiss()
                            } catch {
                                // If auto-generation fails, show error but still allow dismissal
                                keyError = "Failed to auto-generate key: \(error.localizedDescription)"
                                // Still dismiss after a delay so user isn't stuck
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .disabled(isProcessing)
                }
            }
        }
        .interactiveDismissDisabled(isProcessing)
        .onAppear {
            // Auto-focus the key input field when view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isKeyInputFocused = true
            }
        }
    }
    
    private func generateNewKey() {
        if showGeneratedKey && !generatedKey.isEmpty {
            // Use the generated key
            isProcessing = true
            keyError = nil
            
            Task { @MainActor in
                do {
                    try await viewModel.setEncryptionKey(generatedKey)
                    dismiss()
                } catch {
                    isProcessing = false
                    keyError = "Failed to save encryption key: \(error.localizedDescription)"
                }
            }
        } else {
            // Generate new key
            generatedKey = EncryptionService.shared.generateKey()
            showGeneratedKey = true
        }
    }
    
    private func importExistingKey() {
        // Trim whitespace and newlines from input
        let trimmedKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validate key format before processing
        if !trimmedKey.hasPrefix("key_") {
            keyError = "Key must start with 'key_' prefix"
            return
        }
        
        // Validate key characters (after prefix)
        let keyWithoutPrefix = String(trimmedKey.dropFirst(4))
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
        
        isProcessing = true
        keyError = nil
        
        Task { @MainActor in
            do {
                try await viewModel.setEncryptionKey(trimmedKey)
                dismiss()
            } catch {
                isProcessing = false
                keyError = "Failed to save encryption key: \(error.localizedDescription)"
            }
        }
    }
}