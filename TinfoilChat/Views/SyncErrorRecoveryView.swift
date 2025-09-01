//
//  SyncErrorRecoveryView.swift
//  TinfoilChat
//
//  View for handling and recovering from sync errors
//

import SwiftUI

struct SyncErrorRecoveryView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: ChatViewModel
    
    @State private var isRetrying: Bool = false
    @State private var keyInput: String = ""
    @State private var showKeyInput: Bool = false
    @State private var isKeyVisible: Bool = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Error Icon
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.orange)
                    .padding(.top, 32)
                
                // Error Title
                Text("Sync Error")
                    .font(.title)
                    .fontWeight(.bold)
                
                // Error Description
                VStack(spacing: 12) {
                    if viewModel.syncErrors.isEmpty {
                        Text("An error occurred while syncing your chats")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(viewModel.syncErrors.enumerated()), id: \.offset) { index, error in
                                    HStack(alignment: .top) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        Text(error)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .frame(maxHeight: 200)
                    }
                }
                .padding(.horizontal)
                
                // Recovery Options
                VStack(spacing: 16) {
                    // Retry Sync
                    Button(action: retrySync) {
                        Label("Retry Sync", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(isRetrying)
                    
                    // Check for decryption errors
                    if viewModel.syncErrors.contains(where: { $0.contains("decrypt") || $0.contains("encryption") }) {
                        Button(action: {
                            showKeyInput = true
                        }) {
                            Label("Update Encryption Key", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        
                        Button(action: retryDecryption) {
                            Label("Retry Failed Decryptions", systemImage: "lock.open.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.gray.opacity(0.2))
                                .foregroundColor(.primary)
                                .cornerRadius(10)
                        }
                        .disabled(isRetrying)
                    }
                    
                    // Clear errors and continue
                    Button(action: {
                        viewModel.syncErrors.removeAll()
                        dismiss()
                    }) {
                        Text("Continue Without Syncing")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Help Text
                VStack(spacing: 8) {
                    Text("Common Issues:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Network connection issues", systemImage: "wifi.slash")
                        Label("Incorrect encryption key", systemImage: "key")
                        Label("Authentication expired", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding()
            }
            .navigationBarTitle("", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showKeyInput) {
                NavigationView {
                    VStack(spacing: 20) {
                        Text("Update Encryption Key")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Enter your encryption key to decrypt your chats")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        HStack {
                            if isKeyVisible {
                                TextField("Enter encryption key", text: $keyInput)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField("Enter encryption key", text: $keyInput)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .font(.system(.body, design: .monospaced))
                            }
                            
                            Button(action: {
                                isKeyVisible.toggle()
                            }) {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showKeyInput = false
                                keyInput = ""
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                            
                            Button("Update Key") {
                                updateKey()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(keyInput.isEmpty ? Color.gray : Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .disabled(keyInput.isEmpty)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .navigationBarHidden(true)
                }
            }
        }
        .interactiveDismissDisabled(isRetrying)
    }
    
    private func retrySync() {
        isRetrying = true
        viewModel.syncErrors.removeAll()
        
        Task { @MainActor in
            await viewModel.performFullSync()
            isRetrying = false
            
            // Dismiss if sync succeeded
            if viewModel.syncErrors.isEmpty {
                dismiss()
            }
        }
    }
    
    private func retryDecryption() {
        isRetrying = true
        
        Task { @MainActor in
            await viewModel.retryDecryptionWithNewKey()
            isRetrying = false
            
            // Clear decryption-related errors
            viewModel.syncErrors.removeAll { error in
                error.contains("decrypt") || error.contains("encryption")
            }
            
            // Dismiss if no more errors
            if viewModel.syncErrors.isEmpty {
                dismiss()
            }
        }
    }
    
    private func updateKey() {
        Task { @MainActor in
            do {
                await viewModel.setEncryptionKey(keyInput)
                showKeyInput = false
                keyInput = ""
                
                // Retry decryption with new key
                await viewModel.retryDecryptionWithNewKey()
                
                // Clear encryption errors
                viewModel.syncErrors.removeAll { error in
                    error.contains("decrypt") || error.contains("encryption")
                }
                
                // Dismiss if successful
                if viewModel.syncErrors.isEmpty {
                    dismiss()
                }
            } catch {
                // Keep the sheet open and show error
                viewModel.syncErrors.append(error.localizedDescription)
            }
        }
    }
}