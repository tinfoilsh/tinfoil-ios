//
//  SyncEnclaveProjectStore.swift
//  TinfoilChat
//

import Foundation

struct SyncEnclaveProjectStore {
    func createProject(id: String, data: CreateProjectData) async throws -> (ProjectData, Int) {
        let payload = ProjectData(
            name: data.name,
            description: data.description,
            systemInstructions: data.systemInstructions,
            memory: [],
            color: data.color
        )
        let response = try await pushProject(id: id, payload: payload, ifMatch: nil)
        return (payload, etagToSyncVersion(response.etag))
    }

    func updateProject(id: String, data: UpdateProjectData, existing: Project) async throws {
        let payload = Self.mergedProjectData(data, existing: existing)
        _ = try await pushProject(id: id, payload: payload, ifMatch: String(existing.syncVersion))
    }

    static func mergedProjectData(_ data: UpdateProjectData, existing: Project) -> ProjectData {
        ProjectData(
            name: data.name ?? existing.name,
            description: data.description ?? existing.description,
            systemInstructions: data.systemInstructions ?? existing.systemInstructions,
            memory: data.memory ?? existing.memory,
            color: data.color ?? existing.color
        )
    }

    func getProject(id: String) async throws -> (ProjectData, Int)? {
        guard let item = try await pull(scope: .project, ids: [id]).first else { return nil }
        if !item.ok {
            if item.code == WireCodes.notFound { return nil }
            throw CloudStorageError.invalidResponse
        }
        guard let payload = try decode(ProjectData.self, from: item.plaintext) else { return nil }
        return (payload, etagToSyncVersion(item.etag))
    }

    func getProjects(ids: [String]) async throws -> [String: (ProjectData, Int)] {
        guard !ids.isEmpty else { return [:] }
        let items = try await pull(scope: .project, ids: ids)
        var out: [String: (ProjectData, Int)] = [:]
        for item in items {
            guard item.ok else { continue }
            guard let payload = try? decodeIfPresent(ProjectData.self, from: item.plaintext) else { continue }
            out[item.id] = (payload, etagToSyncVersion(item.etag))
        }
        return out
    }

    func deleteProject(id: String) async throws {
        _ = try await SyncEnclaveAPI.deleteRow(
            EnclaveDeleteRequest(
                scope: .project,
                id: id,
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                key: try CEKEncoding.requirePrimaryKeyB64()
            )
        )
    }

    func deleteAllProjects() async throws -> Int {
        let response = try await SyncEnclaveAPI.deleteAllProjects(
            EnclaveDeleteAllProjectsRequest(
                key: try CEKEncoding.requirePrimaryKeyB64(),
                idempotencyKey: newSyncEnclaveIdempotencyKey()
            )
        )
        guard response.ok else { throw CloudStorageError.invalidResponse }
        return response.deleted
    }

    func uploadDocument(
        id: String,
        projectId: String,
        filename: String,
        contentType: String,
        content: String,
        sizeBytes: Int
    ) async throws -> (ProjectDocumentPayload, Int) {
        let payload = ProjectDocumentPayload(
            content: content,
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes
        )
        let metadata: [String: AnyCodable] = [
            "filename": AnyCodable(filename),
            "contentType": AnyCodable(contentType),
            "projectId": AnyCodable(projectId)
        ]
        let response = try await push(
            scope: .projectDocument,
            id: id,
            payload: payload,
            ifMatch: nil,
            metadata: metadata
        )
        return (payload, etagToSyncVersion(response.etag))
    }

    func getDocument(id: String) async throws -> (ProjectDocumentPayload, Int)? {
        guard let item = try await pull(scope: .projectDocument, ids: [id]).first else { return nil }
        if !item.ok {
            if item.code == WireCodes.notFound { return nil }
            throw CloudStorageError.invalidResponse
        }
        guard let payload = try decode(ProjectDocumentPayload.self, from: item.plaintext) else {
            return nil
        }
        return (payload, etagToSyncVersion(item.etag))
    }

    func getDocuments(ids: [String]) async throws -> [String: (ProjectDocumentPayload, Int)] {
        guard !ids.isEmpty else { return [:] }
        let items = try await pull(scope: .projectDocument, ids: ids)
        var out: [String: (ProjectDocumentPayload, Int)] = [:]
        for item in items {
            guard item.ok else { continue }
            guard let payload = try? decodeIfPresent(ProjectDocumentPayload.self, from: item.plaintext) else { continue }
            out[item.id] = (payload, etagToSyncVersion(item.etag))
        }
        return out
    }

    func deleteDocument(id: String) async throws {
        _ = try await SyncEnclaveAPI.deleteRow(
            EnclaveDeleteRequest(
                scope: .projectDocument,
                id: id,
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                key: try CEKEncoding.requirePrimaryKeyB64()
            )
        )
    }

    private func pushProject(id: String, payload: ProjectData, ifMatch: String?) async throws -> EnclavePushResponse {
        try await push(scope: .project, id: id, payload: payload, ifMatch: ifMatch, metadata: nil)
    }

    private func push<T: Encodable>(
        scope: SyncScope,
        id: String,
        payload: T,
        ifMatch: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> EnclavePushResponse {
        let plaintext = try JSONEncoder().encode(payload)
        return try await SyncEnclaveAPI.push(
            EnclavePushRequest(
                scope: scope,
                id: id,
                key: try CEKEncoding.requirePrimaryKeyB64(),
                plaintext: plaintext.base64EncodedString(),
                ifMatch: ifMatch,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                metadata: metadata
            )
        )
    }

    private func pull(scope: SyncScope, ids: [String]) async throws -> [EnclavePullItem] {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return [] }
        let response = try await SyncEnclaveAPI.pull(
            EnclavePullRequest(
                scope: scope,
                ids: ids,
                all: nil,
                cursor: nil,
                limit: nil,
                keys: keys
            )
        )
        return response.items
    }

    private func decode<T: Decodable>(_ type: T.Type, from plaintextB64: String?) throws -> T? {
        guard let plaintextB64,
              let plaintext = Data(base64Encoded: plaintextB64) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: plaintext)
    }

    private func decodeIfPresent<T: Decodable>(_ type: T.Type, from plaintextB64: String?) throws -> T {
        guard let decoded = try decode(type, from: plaintextB64) else {
            throw CloudStorageError.invalidResponse
        }
        return decoded
    }

    private func etagToSyncVersion(_ etag: String?) -> Int {
        guard let etag, let value = Int(etag), value > 0 else { return 1 }
        return value
    }

    private func hasNextCursor(_ cursor: String?) -> Bool {
        guard let cursor else { return false }
        return !cursor.isEmpty
    }
}
