//
//  EncryptedFileStorage.swift
//  TinfoilChat
//
//  Actor-based encrypted file storage for individual chat files.
//  Replaces the single keychain blob with per-chat encrypted files
//  and a lightweight index for metadata queries.
//
//  Two static instances:
//    .local  — device key, stores under {userId}/local/
//    .cloud  — cloud key, stores under {userId}/ (backward compatible)
//    .shared — alias for .cloud (backward compat for callers)
//

import Foundation

actor EncryptedFileStorage {
    static let local = EncryptedFileStorage(
        encryptor: DeviceEncryptionService.shared,
        subdirectory: "local"
    )
    static let cloud = EncryptedFileStorage(
        encryptor: EncryptionService.shared,
        subdirectory: nil
    )
    /// Backward-compatible alias for cloud storage.
    static let shared = cloud

    private let fileManager = FileManager.default
    private let encryptor: any ChatEncryptor
    private let subdirectory: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(encryptor: any ChatEncryptor, subdirectory: String?) {
        self.encryptor = encryptor
        self.subdirectory = subdirectory
    }

    // MARK: - Directory / Path Helpers

    /// Sanitize a path component by removing path separators and parent-directory sequences
    /// to prevent path traversal attacks from server-controlled values.
    private func sanitizePathComponent(_ component: String) -> String {
        return component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    private func chatsDirectory(userId: String) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        var chatsDir = appSupport
            .appendingPathComponent("tinfoil", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(sanitizePathComponent(userId), isDirectory: true)

        if let sub = subdirectory {
            chatsDir = chatsDir.appendingPathComponent(sub, isDirectory: true)
        }

        if !fileManager.fileExists(atPath: chatsDir.path) {
            try fileManager.createDirectory(
                at: chatsDir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }

        return chatsDir
    }

    private func chatFilePath(chatId: String, userId: String, isCorrupted: Bool) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        let ext = isCorrupted ? "raw" : "enc"
        return dir.appendingPathComponent("\(sanitizePathComponent(chatId)).\(ext)")
    }

    private func indexFilePath(userId: String) throws -> URL {
        let dir = try chatsDirectory(userId: userId)
        return dir.appendingPathComponent("index.enc")
    }

    // MARK: - Index Operations

    func loadIndex(userId: String) async throws -> [ChatIndexEntry] {
        let indexPath = try indexFilePath(userId: userId)

        guard fileManager.fileExists(atPath: indexPath.path) else {
            return try await rebuildIndex(userId: userId)
        }

        do {
            let fileData = try Data(contentsOf: indexPath)
            let encrypted = try decoder.decode(EncryptedData.self, from: fileData)
            let decryptedData = try await encryptor.decryptData(encrypted)
            return try decoder.decode([ChatIndexEntry].self, from: decryptedData)
        } catch {
            return try await rebuildIndex(userId: userId)
        }
    }

    func saveIndex(_ entries: [ChatIndexEntry], userId: String) async throws {
        let indexPath = try indexFilePath(userId: userId)
        let jsonData = try encoder.encode(entries)
        let encrypted = try await encryptor.encryptData(jsonData)
        let fileData = try encoder.encode(encrypted)
        try fileData.write(to: indexPath, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Chat Operations

    func saveChat(_ chat: Chat, userId: String) async throws {
        var entries = (try? await loadIndex(userId: userId)) ?? []
        let chatToSave = chat

        let isCorrupted = chatToSave.decryptionFailed || chatToSave.dataCorrupted

        let data = try encoder.encode(chatToSave)

        if isCorrupted {
            // Write as plain JSON — the encryptedData field already contains
            // the original encrypted payload for future decryption retry
            let filePath = try chatFilePath(chatId: chatToSave.id, userId: userId, isCorrupted: true)
            try data.write(to: filePath, options: [.atomic, .completeFileProtection])

            // Remove any stale .enc file for this chat
            let encPath = try chatFilePath(chatId: chatToSave.id, userId: userId, isCorrupted: false)
            if fileManager.fileExists(atPath: encPath.path) {
                try? fileManager.removeItem(at: encPath)
            }
        } else {
            let encrypted = try await encryptor.encryptData(data)
            let encryptedData = try encoder.encode(encrypted)
            let filePath = try chatFilePath(chatId: chatToSave.id, userId: userId, isCorrupted: false)
            try encryptedData.write(to: filePath, options: [.atomic, .completeFileProtection])

            // Remove any stale .raw file for this chat
            let rawPath = try chatFilePath(chatId: chatToSave.id, userId: userId, isCorrupted: true)
            if fileManager.fileExists(atPath: rawPath.path) {
                try? fileManager.removeItem(at: rawPath)
            }
        }

        // Update index: upsert and save
        let newEntry = ChatIndexEntry(from: chatToSave)
        if let idx = entries.firstIndex(where: { $0.id == chatToSave.id }) {
            entries[idx] = newEntry
        } else {
            entries.append(newEntry)
        }
        try await saveIndex(entries, userId: userId)
    }

    func loadChat(chatId: String, userId: String) async throws -> Chat? {
        // Try .enc file first
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        if fileManager.fileExists(atPath: encPath.path) {
            return try await loadChatFromFile(encPath, isRaw: false)
        }

        // Try .raw file
        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        if fileManager.fileExists(atPath: rawPath.path) {
            return try await loadChatFromFile(rawPath, isRaw: true)
        }

        // Neither exists — remove stale index entry if present
        var entries = (try? await loadIndex(userId: userId)) ?? []
        if entries.contains(where: { $0.id == chatId }) {
            entries.removeAll { $0.id == chatId }
            try? await saveIndex(entries, userId: userId)
        }

        return nil
    }

    func deleteChat(chatId: String, userId: String) async throws {
        let encPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: false)
        if fileManager.fileExists(atPath: encPath.path) {
            try fileManager.removeItem(at: encPath)
        }

        let rawPath = try chatFilePath(chatId: chatId, userId: userId, isCorrupted: true)
        if fileManager.fileExists(atPath: rawPath.path) {
            try fileManager.removeItem(at: rawPath)
        }

        var entries = (try? await loadIndex(userId: userId)) ?? []
        entries.removeAll { $0.id == chatId }
        try await saveIndex(entries, userId: userId)
    }

    func deleteAllChats(userId: String) throws {
        let dir = try chatsDirectory(userId: userId)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    /// Atomically update only sync metadata fields on a chat without
    /// touching messages or other content. This avoids the race where a
    /// full load-modify-save could overwrite in-progress user edits.
    func updateSyncMetadata(
        chatId: String,
        userId: String,
        syncVersion: Int,
        syncedAt: Date,
        locallyModified: Bool
    ) async throws {
        guard var chat = try await loadChat(chatId: chatId, userId: userId) else { return }
        chat.syncVersion = syncVersion
        chat.syncedAt = syncedAt
        chat.locallyModified = locallyModified
        try await saveChat(chat, userId: userId)
    }

    // MARK: - Bulk Operations

    func loadChats(chatIds: [String], userId: String) async throws -> [Chat] {
        var chats: [Chat] = []
        for chatId in chatIds {
            if let chat = try await loadChat(chatId: chatId, userId: userId) {
                chats.append(chat)
            }
        }
        return chats
    }

    func loadAllChats(userId: String) async throws -> [Chat] {
        let entries = try await loadIndex(userId: userId)
        return try await loadChats(chatIds: entries.map(\.id), userId: userId)
    }

    // MARK: - Error Recovery

    func rebuildIndex(userId: String) async throws -> [ChatIndexEntry] {
        let dir = try chatsDirectory(userId: userId)
        let contents = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []

        var entries: [ChatIndexEntry] = []

        for fileURL in contents {
            let ext = fileURL.pathExtension
            guard ext == "enc" || ext == "raw" else { continue }

            let chatId = fileURL.deletingPathExtension().lastPathComponent
            guard chatId != "index" else { continue }

            if let chat = try? await loadChatFromFile(fileURL, isRaw: ext == "raw") {
                entries.append(ChatIndexEntry(from: chat))
            }
        }

        try await saveIndex(entries, userId: userId)
        return entries
    }

    // MARK: - Private Helpers

    private func loadChatFromFile(_ fileURL: URL, isRaw: Bool) async throws -> Chat? {
        let data = try Data(contentsOf: fileURL)

        if isRaw {
            return try decoder.decode(Chat.self, from: data)
        } else {
            let encrypted = try decoder.decode(EncryptedData.self, from: data)
            let decryptedData = try await encryptor.decryptData(encrypted)
            return try decoder.decode(Chat.self, from: decryptedData)
        }
    }
}
