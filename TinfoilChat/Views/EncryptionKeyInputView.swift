//
//  EncryptionKeyInputView.swift
//  TinfoilChat
//
//  Reusable view for importing encryption keys
//

import SwiftUI
import AVFoundation

struct EncryptionKeyInputView: View {
    @Binding var isPresented: Bool
    let onKeyImported: ((String) -> Void)?
    
    @State private var keyInput: String = ""
    @State private var keyError: String? = nil
    @State private var isKeyVisible: Bool = false
    @State private var showQRScanner = false
    @FocusState private var isKeyFieldFocused: Bool
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header explanation
                VStack(spacing: 20) {
                    // Title and description
                    VStack(spacing: 8) {
                        Text(isKeyFieldFocused ? "Enter your encryption key" : "Encryption Key")
                            .font(isKeyFieldFocused ? .headline : .title2)
                            .fontWeight(.semibold)
                        
                        if !isKeyFieldFocused {
                            Text("Your encryption key secures all your chat data. You can enter it manually or scan the QR code from your other device.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                }
                
                // Input section
                VStack(spacing: 24) {
                    // Manual input section
                    VStack(alignment: .leading, spacing: 12) {
                        if !isKeyFieldFocused {
                            Label("Enter Key Manually", systemImage: "keyboard")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                        }
                        
                        HStack(spacing: 8) {
                            Group {
                                if isKeyVisible {
                                    TextField("key_...", text: $keyInput)
                                } else {
                                    SecureField("key_...", text: $keyInput)
                                }
                            }
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                            .focused($isKeyFieldFocused)
                            .onChange(of: keyInput) { _, newValue in
                                validateKey(newValue)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(UIColor.secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        keyError != nil ? Color.red.opacity(0.5) : 
                                        isKeyFieldFocused ? Color.accentPrimary : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            
                            Button(action: {
                                isKeyVisible.toggle()
                            }) {
                                Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(12)
                            }
                        }
                        
                        if let error = keyError {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    // Show OR divider and QR button only when not focused
                    if !isKeyFieldFocused {
                        // Divider with "OR"
                        HStack {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                            
                            Text("OR")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                            
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                        }
                        .padding(.vertical, 8)
                        
                        // QR Code scan button
                        Button(action: {
                            requestCameraPermission { granted in
                                if granted {
                                    showQRScanner = true
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.title3)
                                Text("Scan QR Code")
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentPrimary)
                            .cornerRadius(12)
                        }
                    }
                    
                    // Import button - always visible but repositioned when focused
                    Button(action: {
                        if keyError == nil && !keyInput.isEmpty {
                            importKey()
                        }
                    }) {
                        Text("Import Key")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(keyInput.isEmpty || keyError != nil ? 
                                          Color.gray.opacity(0.5) : Color.accentPrimary)
                            )
                    }
                    .disabled(keyInput.isEmpty || keyError != nil)
                    .padding(.top, isKeyFieldFocused ? 8 : 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                
                Spacer()
                
                // Bottom safety text - only when not focused
                if !isKeyFieldFocused {
                    Text("Keep your key safe and never share it")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("Import Encryption Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                // Add Done button when keyboard is shown
                if isKeyFieldFocused {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            isKeyFieldFocused = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerView { scannedKey in
                showQRScanner = false
                keyInput = scannedKey
                validateKey(scannedKey)
                
                // Auto-import if valid
                if keyError == nil {
                    importKey()
                }
            }
        }
    }
    
    private func validateKey(_ key: String) {
        keyError = nil
        
        if key.isEmpty {
            return
        }
        
        if !key.hasPrefix("key_") {
            keyError = "Key must start with 'key_' prefix"
            return
        }
        
        let keyWithoutPrefix = String(key.dropFirst(4))
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if keyWithoutPrefix.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
            keyError = "Key must only contain lowercase letters and numbers after the prefix"
            return
        }
        
        if keyWithoutPrefix.count % 2 != 0 {
            keyError = "Invalid key length"
            return
        }
    }
    
    private func importKey() {
        onKeyImported?(keyInput)
        isPresented = false
    }
    
    private func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            let alert = UIAlertController(
                title: "Camera Access Required",
                message: "Please enable camera access in Settings to scan QR codes.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(alert, animated: true)
            }
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}