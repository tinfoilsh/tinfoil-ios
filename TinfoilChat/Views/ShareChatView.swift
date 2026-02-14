//
//  ShareChatView.swift
//  TinfoilChat
//
//  Share conversation sheet.
//

import SwiftUI

struct ShareChatView: View {
    let messages: [Message]
    let chatTitle: String?
    let chatCreatedAt: Date?
    let chatId: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var isShareEnabled = false
    @State private var shareUrl: String?
    @State private var isUploading = false
    @State private var isLinkCopied = false
    @State private var errorMessage: String?

    private var isDark: Bool { colorScheme == .dark }

    private var sheetBackground: Color {
        isDark ? Color(hex: "161616") : Color(UIColor.systemGroupedBackground)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                titleCard
                accessCard
                errorText
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(sheetBackground)
            .navigationTitle("Share snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
        }
        .presentationBackground(sheetBackground)
    }

    // MARK: - Title card

    private var titleCard: some View {
        HStack {
            Text(chatTitle ?? "Untitled")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Image(systemName: "bubble.left.fill")
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(cardColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Access card

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who has access")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            accessOptions
            actionButton
            linkRow
        }
    }

    private var accessOptions: some View {
        VStack(spacing: 0) {
            accessRow(icon: "lock.fill", label: "Only you have access", selected: !isShareEnabled) {
                selectPrivate()
            }

            Divider().padding(.leading, 48)

            accessRow(icon: "globe", label: "Anyone with the link", selected: isShareEnabled) {
                isShareEnabled = true
            }
        }
        .background(cardColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func accessRow(icon: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Text(label)
                    .font(.system(size: 15))

                Spacer()

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actionButton: some View {
        Button(action: handleShareLink) {
            Group {
                if isUploading {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text("Uploading...")
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share Link")
                    }
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.tinfoilAccentDark.opacity(isShareEnabled && shareUrl == nil ? 1.0 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!isShareEnabled || isUploading || chatId == nil || shareUrl != nil)
    }

    private func selectPrivate() {
        isShareEnabled = false
        shareUrl = nil
        isLinkCopied = false
    }

    // MARK: - Error

    @ViewBuilder
    private var errorText: some View {
        if let error = errorMessage {
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Link row (shown after upload)

    @ViewBuilder
    private var linkRow: some View {
        if isShareEnabled, let url = shareUrl {
            HStack(spacing: 8) {
                Text(url)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(isDark ? .white.opacity(0.6) : .black.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button(action: copyShareUrl) {
                    HStack(spacing: 4) {
                        Image(systemName: isLinkCopied ? "checkmark" : "doc.on.doc")
                        Text(isLinkCopied ? "Copied!" : "Copy")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(height: 44)
                    .padding(.horizontal, 14)
                    .background(Color.tinfoilAccentDark)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Only messages up to this point will be shared")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var cardColor: Color {
        isDark ? Color.white.opacity(0.05) : Color(UIColor.secondarySystemGroupedBackground)
    }

    // MARK: - Actions

    private func handleShareLink() {
        guard let chatId = chatId else {
            errorMessage = "Chat must be saved before sharing"
            return
        }

        isUploading = true
        errorMessage = nil

        // Capture view data on main thread before offloading
        let capturedMessages = messages
        let title = chatTitle
        let createdAt = chatCreatedAt

        Task.detached {
            do {
                let shareableData = ShareChatView.buildShareableData(
                    messages: capturedMessages, chatTitle: title, chatCreatedAt: createdAt
                )
                let key = ShareEncryptionService.generateShareKey()
                let encrypted = try ShareEncryptionService.encryptForShare(shareableData, key: key)
                let keyBase64url = ShareEncryptionService.exportKeyToBase64url(key)

                try await ShareAPIService.uploadSharedChat(chatId: chatId, encryptedData: encrypted)

                let url = "\(Constants.Share.shareBaseURL)/share/\(chatId)#\(keyBase64url)"

                await MainActor.run {
                    shareUrl = url
                    isUploading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isUploading = false
                }
            }
        }
    }

    private func copyShareUrl() {
        guard let url = shareUrl else { return }
        UIPasteboard.general.string = url
        isLinkCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Share.copyFeedbackDurationSeconds) {
            isLinkCopied = false
        }
    }

    private static func buildShareableData(messages: [Message], chatTitle: String?, chatCreatedAt: Date?) -> ShareableChatData {
        let shareableMessages = messages.map { msg in
            let docContent: String? = {
                let docs = msg.attachments.filter { $0.type == .document && $0.textContent != nil }
                guard !docs.isEmpty else { return nil }
                return docs.map { "Document title: \($0.fileName)\nDocument contents:\n\($0.textContent ?? "")" }
                    .joined(separator: "\n\n")
            }()

            let docs: [ShareableChatData.ShareableDocument]? = msg.attachments.isEmpty
                ? nil
                : msg.attachments.map { ShareableChatData.ShareableDocument(name: $0.fileName) }

            return ShareableChatData.ShareableMessage(
                role: msg.role.rawValue,
                content: msg.content,
                documentContent: docContent,
                documents: docs,
                timestamp: msg.timestamp.timeIntervalSince1970 * 1000,
                thoughts: msg.thoughts,
                thinkingDuration: msg.thinkingDuration ?? msg.generationTimeSeconds,
                isError: msg.isError
            )
        }

        return ShareableChatData(
            v: Constants.Share.formatVersion,
            title: chatTitle ?? "Shared Chat",
            messages: shareableMessages,
            createdAt: (chatCreatedAt ?? Date()).timeIntervalSince1970 * 1000
        )
    }
}

