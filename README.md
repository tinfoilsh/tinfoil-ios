# Tinfoil Chat (iOS)

**Available on:** [App Store](https://apps.apple.com/us/app/tinfoil-private-ai/id6745201750)

## Security Architecture

Tinfoil Chat is designed to ensure that only the AI model inside a verified secure enclave can read your messages - not Tinfoil, not cloud providers, not network intermediaries.

### How it works

We use the [Tinfoil Swift SDK](https://github.com/tinfoilsh/tinfoil-swift) to establish secure, end-to-end encrypted communication with AI models running in verified secure enclaves. All data from the iOS app is encrypted with keys that are generated and live only inside the secure enclave.

Before sending any message:

1. **Attestation Verification**: The app cryptographically verifies that the remote server is a genuine secure enclave running unmodified code
2. **Key Exchange**: The verified enclave provides its encryption public key
3. **End-to-End Encryption**: Messages are encrypted directly to the verified enclave's public key before transmission

This guarantees that only the attested enclave possessing the corresponding private key can decrypt your messages.

### Encrypted Chat Storage

Your saved chats are encrypted on your device using AES-GCM-256 encryption, with a key only you control. Chats are stored securely in the iOS Keychain and backed up to encrypted cloud storage (Cloudflare R2).

If you lose your encryption key, your chat history cannot be recovered.

### Verification Steps

The chat interface shows real-time verification status for:

- **Hardware Attestation**: Confirms genuine AMD SEV-SNP or Intel TDX enclave and genuine NVIDIA Hopper/Blackwell GPU
- **Code Integrity**: Verifies enclave runs the exact, unmodified code version matching the pinned code on Sigstore
- **Chat Security**: Validates measurements fetched from Sigstore match measurements fetched from enclave

Learn more about the security model:

- [Tinfoil Swift SDK](https://github.com/tinfoilsh/tinfoil-swift)
- [Tinfoil Documentation](https://docs.tinfoil.sh)

## Architecture Overview

The app is structured around several key components:

- **[ViewModels/ChatViewModel.swift](TinfoilChat/ViewModels/ChatViewModel.swift)**: Core chat logic and streaming message handling
- **[Services/EncryptionService.swift](TinfoilChat/Services/EncryptionService.swift)**: AES-GCM encryption for local chat storage
- **[Services/KeychainChatStorage.swift](TinfoilChat/Services/KeychainChatStorage.swift)**: Secure storage in iOS Keychain
- **[Services/CloudSyncService.swift](TinfoilChat/Services/CloudSyncService.swift)**: Encrypted cloud backup functionality
- **[Extensions/Model+Tinfoil.swift](TinfoilChat/Extensions/Model+Tinfoil.swift)**: Integration with Tinfoil Swift SDK

## Reporting Vulnerabilities

Please report security vulnerabilities by either:

- Emailing [security@tinfoil.sh](mailto:security@tinfoil.sh)
- Opening an issue on GitHub on this repository

We aim to respond to security reports within 24 hours and will keep you updated on our progress.
