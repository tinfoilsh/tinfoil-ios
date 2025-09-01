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
            VStack(spacing: 20) {
                HStack {
                    if isKeyVisible {
                        TextField("Enter encryption key (key_...)", text: $keyInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                            .focused($isKeyFieldFocused)
                            .onChange(of: keyInput) { _, newValue in
                                validateKey(newValue)
                            }
                    } else {
                        SecureField("Enter encryption key (key_...)", text: $keyInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                            .focused($isKeyFieldFocused)
                            .onChange(of: keyInput) { _, newValue in
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
                
                HStack(spacing: 12) {
                    Button("Import Key") {
                        if keyError == nil && !keyInput.isEmpty {
                            importKey()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(keyInput.isEmpty || keyError != nil ? Color.gray : Color.accentPrimary)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(keyInput.isEmpty || keyError != nil)
                    
                    Button(action: {
                        requestCameraPermission { granted in
                            if granted {
                                showQRScanner = true
                            }
                        }
                    }) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Color.accentPrimary)
                            .cornerRadius(10)
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Import Encryption Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isKeyFieldFocused = true
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