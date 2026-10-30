# Building and Running

NEVER build or run the project using xcodebuild or any other compilation commands. Only make code changes and let the user handle building, running, and testing in Xcode.

# Chat Service Protocol

The chat harness's wire types come from `harness-protocol/openapi.yaml` through the generated `TinfoilChat/Services/Harness/Protocol/`; `HarnessProtocol.swift` only names them. Never hand-write a harness response, record or event type, or edit the generated files: run `scripts/sync-harness-protocol.sh <harness checkout>` to copy the protocol and its recorded runs from the harness and generate the types again. Every request to the harness goes through `HarnessClient`, which verifies the enclave and seals each body to it. A harness error with a code this client has no handling for is handled by its `action`; every error this client creates names one too.
