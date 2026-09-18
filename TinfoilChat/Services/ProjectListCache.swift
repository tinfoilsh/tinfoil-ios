//
//  ProjectListCache.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.

import Foundation

/// On-device copy of the last project list fetched for a user, so the
/// sidebar can show projects immediately on launch instead of waiting for
/// the cloud sync. Sealed with the device key: project names, descriptions,
/// and memory are user content and never touch disk in plaintext.
actor ProjectListCache {
    static let shared = ProjectListCache(encryptor: DeviceEncryptionService.shared)

    private let fileManager = FileManager.default
    private let encryptor: any ChatEncryptor
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(encryptor: any ChatEncryptor) {
        self.encryptor = encryptor
    }

    func load(userId: String) async -> [Project] {
        guard let path = try? filePath(userId: userId),
              fileManager.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path) else {
            return []
        }
        do {
            let envelope = try decoder.decode(EncryptedData.self, from: data)
            let plaintext = try await encryptor.decryptData(envelope)
            return try decoder.decode([Project].self, from: plaintext)
        } catch {
            // A cache that no longer decodes is disposable: the next fetch
            // rewrites it, so drop it rather than failing on every launch.
            try? fileManager.removeItem(at: path)
            return []
        }
    }

    func save(_ projects: [Project], userId: String) async {
        // Placeholders for undecryptable projects carry no useful content
        // and would otherwise mask a later successful decrypt.
        let cacheable = projects.filter { $0.decryptionFailed != true }
        guard let path = try? filePath(userId: userId) else { return }
        do {
            let plaintext = try encoder.encode(cacheable)
            let envelope = try await encryptor.encryptData(plaintext)
            let data = try encoder.encode(envelope)
            try data.write(to: path, options: [.atomic, .completeFileProtection])
        } catch {
            try? fileManager.removeItem(at: path)
        }
    }

    func clear(userId: String) {
        guard let path = try? filePath(userId: userId) else { return }
        try? fileManager.removeItem(at: path)
    }

    private func filePath(userId: String) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("tinfoil", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(sanitizePathComponent(userId), isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        return directory.appendingPathComponent(Constants.ProjectListCache.fileName)
    }

    private func sanitizePathComponent(_ component: String) -> String {
        component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }
}
