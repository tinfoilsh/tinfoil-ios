# Tinfoil Chat (iOS)

**Available on:** [App Store](https://apps.apple.com/us/app/tinfoil-private-ai/id6745201750)

The iOS app for Tinfoil Chat, a private AI assistant. Before sending a message, the app verifies that the model runs in an attested secure enclave and encrypts the message to that enclave with the [Tinfoil Swift SDK](https://github.com/tinfoilsh/tinfoil-swift). Saved chats are encrypted on the device with a key only the user controls before they sync to the cloud.

- [Tinfoil Chat overview](https://docs.tinfoil.sh/chat/overview)
- [Cloud sync and encryption](https://docs.tinfoil.sh/chat/cloud-sync)
- [How verification works in Tinfoil](https://docs.tinfoil.sh/verification/verification-in-tinfoil)

## Development

Open `TinfoilChat.xcodeproj` in Xcode and run the `TinfoilChat` scheme.

## Reporting Vulnerabilities

Please report security vulnerabilities by either:

- Emailing [security@tinfoil.sh](mailto:security@tinfoil.sh)
- Opening an issue on GitHub on this repository

We aim to respond to (legitimate) security reports within 24 hours.
