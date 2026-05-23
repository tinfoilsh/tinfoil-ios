//
//  ProjectStorageService.swift
//  TinfoilChat
//
//  Cloud storage API for webapp-compatible Projects built on the
//  attested sync enclave. Mirrors
//  `services/cloud/project-storage.ts` in the webapp.
//
//  Two scopes are involved:
//    - `project`            : the project metadata blob (name, description,
//                             system instructions, memory facts).
//    - `project_document`   : per-document content. The wire id is
//                             "<projectId>/<documentId>" so the enclave
//                             can route them under one scope.
//

import ClerkKit
import Foundation

final class ProjectStorageService: ObservableObject {
    static let shared = ProjectStorageService()

    private let projectListLimit = Constants.SyncEnclave.projectListLimit
    private var getToken: (() async -> String?)? = nil

    private init() {}

    // MARK: - Configuration

    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) {
        self.getToken = tokenGetter
        let captured = tokenGetter
        Task {
            await SyncEnclaveClient.shared.setTokenGetter { await captured() }
        }
    }

    private func defaultTokenGetter() async -> String? {
        do {
            guard !Clerk.shared.publishableKey.isEmpty else { return nil }
            if !Clerk.shared.isLoaded {
                try await Clerk.shared.refreshClient()
            }
            if let session = Clerk.shared.session {
                if let token = try? await session.getToken() {
                    return token
                }
                return session.lastActiveToken?.jwt
            }
            return nil
        } catch {
            return nil
        }
    }

    func isAuthenticated() async -> Bool {
        let token = await (getToken ?? defaultTokenGetter)()
        return token?.isEmpty == false
    }

    // MARK: - Controlplane helpers (ID generation only)

    private func controlplaneHeaders(contentType: String = "application/json") async throws -> [String: String] {
        guard let token = await (getToken ?? defaultTokenGetter)(), !token.isEmpty else {
            throw CloudStorageError.authenticationRequired
        }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": contentType
        ]
    }

    func generateProjectId() async throws -> GenerateProjectIdResponse {
        var request = URLRequest(url: URL(string: "\(Constants.API.baseURL)/api/projects/generate-id")!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await controlplaneHeaders()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudStorageError.invalidResponse
        }
        return try JSONDecoder().decode(GenerateProjectIdResponse.self, from: data)
    }

    func generateDocumentId(projectId: String) async throws -> GenerateDocumentIdResponse {
        var request = URLRequest(url: URL(string: "\(Constants.API.baseURL)/api/projects/\(projectId)/documents/generate-id")!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await controlplaneHeaders()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudStorageError.invalidResponse
        }
        return try JSONDecoder().decode(GenerateDocumentIdResponse.self, from: data)
    }

    // MARK: - Project CRUD

    func createProject(_ data: CreateProjectData) async throws -> Project {
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        let idResponse = try await generateProjectId()
        let payload = ProjectData(
            name: data.name,
            description: data.description,
            systemInstructions: data.systemInstructions,
            memory: []
        )
        let plaintext = try JSONEncoder().encode(payload)

        let response = try await SyncEnclaveAPI.push(
            EnclavePushRequest(
                scope: .project,
                id: idResponse.projectId,
                key: keyB64,
                plaintext: plaintext.base64EncodedString(),
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                metadata: nil
            )
        )

        let now = isoNow()
        return Project(
            id: idResponse.projectId,
            name: payload.name,
            description: payload.description,
            systemInstructions: payload.systemInstructions,
            memory: payload.memory,
            createdAt: now,
            updatedAt: now,
            syncVersion: etagToSyncVersion(response.etag)
        )
    }

    func updateProject(_ projectId: String, data: UpdateProjectData) async throws {
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        guard let existing = try await getProject(projectId) else {
            throw CloudStorageError.invalidResponse
        }
        let payload = ProjectData(
            name: data.name ?? existing.name,
            description: data.description ?? existing.description,
            systemInstructions: data.systemInstructions ?? existing.systemInstructions,
            memory: data.memory ?? existing.memory
        )
        let plaintext = try JSONEncoder().encode(payload)

        _ = try await SyncEnclaveAPI.push(
            EnclavePushRequest(
                scope: .project,
                id: projectId,
                key: keyB64,
                plaintext: plaintext.base64EncodedString(),
                ifMatch: String(existing.syncVersion),
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                metadata: nil
            )
        )
    }

    func getProject(_ projectId: String) async throws -> Project? {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return nil }
        do {
            let response = try await SyncEnclaveAPI.pull(
                EnclavePullRequest(
                    scope: .project,
                    ids: [projectId],
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            )
            guard let item = response.items.first else { return nil }
            if !item.ok {
                if item.code == WireCodes.notFound { return nil }
                return nil
            }
            guard let b64 = item.plaintext,
                  let plaintext = Data(base64Encoded: b64) else { return nil }
            let decoded = try JSONDecoder().decode(ProjectData.self, from: plaintext)
            let now = isoNow()
            return Project(
                id: projectId,
                name: decoded.name,
                description: decoded.description,
                systemInstructions: decoded.systemInstructions,
                memory: decoded.memory,
                createdAt: now,
                updatedAt: now,
                syncVersion: etagToSyncVersion(item.etag)
            )
        } catch {
            return nil
        }
    }

    func getProjects(_ projectIds: [String]) async throws -> [String: Project] {
        guard !projectIds.isEmpty else { return [:] }
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return [:] }
        let response = try await SyncEnclaveAPI.pull(
            EnclavePullRequest(
                scope: .project,
                ids: projectIds,
                all: nil,
                cursor: nil,
                limit: nil,
                keys: keys
            )
        )
        var out: [String: Project] = [:]
        for item in response.items {
            guard item.ok,
                  let b64 = item.plaintext,
                  let plaintext = Data(base64Encoded: b64),
                  let decoded = try? JSONDecoder().decode(ProjectData.self, from: plaintext) else {
                continue
            }
            let now = isoNow()
            out[item.id] = Project(
                id: item.id,
                name: decoded.name,
                description: decoded.description,
                systemInstructions: decoded.systemInstructions,
                memory: decoded.memory,
                createdAt: now,
                updatedAt: now,
                syncVersion: etagToSyncVersion(item.etag)
            )
        }
        return out
    }

    func deleteProject(_ projectId: String) async throws {
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        _ = try await SyncEnclaveAPI.deleteRow(
            EnclaveDeleteRequest(
                scope: .project,
                id: projectId,
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                key: keyB64
            )
        )
    }

    @discardableResult
    func deleteAllProjects() async throws -> Int {
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        var deleted = 0
        var cursor: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(scope: .project, cursor: cursor, limit: 500, projectId: nil)
            )
            for update in status.updates {
                _ = try await SyncEnclaveAPI.deleteRow(
                    EnclaveDeleteRequest(
                        scope: .project,
                        id: update.id,
                        ifMatch: nil,
                        idempotencyKey: newSyncEnclaveIdempotencyKey(),
                        key: keyB64
                    )
                )
                deleted += 1
            }
            cursor = status.nextCursor
        } while hasNextCursor(cursor)
        return deleted
    }

    func listProjects(
        limit: Int = Constants.Pagination.projectsPerPage,
        continuationToken: String? = nil,
        includeContent: Bool = true
    ) async throws -> ProjectListResponse {
        let pageLimit = min(limit, 500)
        let status = try await SyncEnclaveAPI.listStatus(
            EnclaveListStatusRequest(
                scope: .project,
                cursor: continuationToken,
                limit: pageLimit,
                projectId: nil
            )
        )
        let projects = status.updates.map { update -> ProjectListItem in
            ProjectListItem(
                id: update.id,
                key: update.id,
                createdAt: createdAtFromReverseId(update.id),
                updatedAt: update.updatedAt,
                syncVersion: etagToSyncVersion(update.etag),
                size: nil,
                content: nil
            )
        }
        return ProjectListResponse(
            projects: projects,
            nextContinuationToken: status.nextCursor,
            hasMore: hasNextCursor(status.nextCursor)
        )
    }

    func loadProjects(limit: Int = Constants.Pagination.projectsPerPage) async throws -> [Project] {
        var allItems: [ProjectListItem] = []
        var continuationToken: String? = nil
        repeat {
            let response = try await listProjects(
                limit: limit,
                continuationToken: continuationToken,
                includeContent: true
            )
            allItems.append(contentsOf: response.projects)
            continuationToken = response.hasMore ? response.nextContinuationToken : nil
        } while continuationToken != nil && !(continuationToken?.isEmpty ?? true)

        let ids = allItems.map(\.id)
        let projects = (try? await getProjects(ids)) ?? [:]
        return allItems.map { item -> Project in
            if let p = projects[item.id] {
                var updated = p
                updated.createdAt = item.createdAt
                updated.updatedAt = item.updatedAt
                return updated
            }
            return Project(
                id: item.id,
                name: "Encrypted",
                description: "",
                systemInstructions: "",
                memory: [],
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                syncVersion: item.syncVersion,
                decryptionFailed: true
            )
        }
    }

    // MARK: - Project sync status

    func getProjectSyncStatus() async throws -> ProjectSyncStatus {
        var count = 0
        var lastUpdated: String? = nil
        var cursor: String? = nil
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(scope: .project, cursor: cursor, limit: 500, projectId: nil)
            )
            count += status.updates.count
            for update in status.updates {
                if let prev = lastUpdated {
                    if update.updatedAt > prev { lastUpdated = update.updatedAt }
                } else {
                    lastUpdated = update.updatedAt
                }
            }
            cursor = status.nextCursor
        } while hasNextCursor(cursor)
        return ProjectSyncStatus(count: count, lastUpdated: lastUpdated)
    }

    func getProjectsUpdatedSince(
        since: String,
        continuationToken: String? = nil
    ) async throws -> ProjectListResponse {
        var cursor: String? = continuationToken ?? since
        var nextContinuationToken: String? = nil
        var projects: [ProjectListItem] = []
        repeat {
            let status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: .project,
                    cursor: cursor,
                    limit: projectListLimit,
                    projectId: nil
                )
            )
            projects.append(contentsOf: status.updates
                .filter { $0.updatedAt > since }
                .map { update -> ProjectListItem in
                    ProjectListItem(
                        id: update.id,
                        key: update.id,
                        createdAt: createdAtFromReverseId(update.id),
                        updatedAt: update.updatedAt,
                        syncVersion: etagToSyncVersion(update.etag),
                        size: nil,
                        content: nil
                    )
                })
            cursor = status.nextCursor
            nextContinuationToken = status.nextCursor
            if projects.count >= projectListLimit { break }
        } while hasNextCursor(cursor)

        return ProjectListResponse(
            projects: projects,
            nextContinuationToken: nextContinuationToken,
            hasMore: hasNextCursor(nextContinuationToken)
        )
    }

    // MARK: - Documents

    func uploadDocument(
        projectId: String,
        filename: String,
        contentType: String,
        content: String
    ) async throws -> ProjectDocument {
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        let idResponse = try await generateDocumentId(projectId: projectId)
        let payload = ProjectDocumentPayload(content: content, filename: filename, contentType: contentType)
        let plaintext = try JSONEncoder().encode(payload)

        let metadata: [String: AnyCodable] = [
            "filename": AnyCodable(filename),
            "contentType": AnyCodable(contentType),
            "projectId": AnyCodable(projectId)
        ]

        let response = try await SyncEnclaveAPI.push(
            EnclavePushRequest(
                scope: .projectDocument,
                id: projectDocumentId(projectId: projectId, documentId: idResponse.documentId),
                key: keyB64,
                plaintext: plaintext.base64EncodedString(),
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                metadata: metadata
            )
        )

        let now = isoNow()
        let size = content.data(using: .utf8)?.count ?? content.count
        return ProjectDocument(
            id: idResponse.documentId,
            projectId: projectId,
            filename: filename,
            contentType: contentType,
            sizeBytes: size,
            syncVersion: etagToSyncVersion(response.etag),
            createdAt: now,
            updatedAt: now,
            content: content
        )
    }

    func getDocument(projectId: String, documentId: String) async throws -> ProjectDocument? {
        guard let keys = CEKEncoding.pullKeysIfAvailable() else { return nil }
        let wireId = projectDocumentId(projectId: projectId, documentId: documentId)
        let response = try await SyncEnclaveAPI.pull(
            EnclavePullRequest(
                scope: .projectDocument,
                ids: [wireId],
                all: nil,
                cursor: nil,
                limit: nil,
                keys: keys
            )
        )
        guard let item = response.items.first else { return nil }
        if !item.ok {
            if item.code == WireCodes.notFound { return nil }
            return nil
        }
        guard let b64 = item.plaintext,
              let plaintext = Data(base64Encoded: b64),
              let decoded = try? JSONDecoder().decode(ProjectDocumentPayload.self, from: plaintext) else {
            return nil
        }
        let now = isoNow()
        return ProjectDocument(
            id: documentId,
            projectId: projectId,
            filename: decoded.filename,
            contentType: decoded.contentType,
            sizeBytes: decoded.content.data(using: .utf8)?.count ?? decoded.content.count,
            syncVersion: etagToSyncVersion(item.etag),
            createdAt: now,
            updatedAt: now,
            content: decoded.content
        )
    }

    func listDocuments(projectId: String, includeContent: Bool = true) async throws -> [ProjectDocument] {
        var status = try await SyncEnclaveAPI.listStatus(
            EnclaveListStatusRequest(scope: .projectDocument, cursor: nil, limit: 500, projectId: nil)
        )
        var allUpdates = status.updates
        while hasNextCursor(status.nextCursor) {
            status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: .projectDocument,
                    cursor: status.nextCursor,
                    limit: 500,
                    projectId: nil
                )
            )
            allUpdates.append(contentsOf: status.updates)
        }
        let projectPrefix = "\(projectId)/"
        let scoped = allUpdates.filter { $0.id.hasPrefix(projectPrefix) }
        if scoped.isEmpty { return [] }

        if includeContent {
            let ids = scoped.map { $0.id }
            guard let keys = CEKEncoding.pullKeysIfAvailable() else { return [] }
            let response = try await SyncEnclaveAPI.pull(
                EnclavePullRequest(
                    scope: .projectDocument,
                    ids: ids,
                    all: nil,
                    cursor: nil,
                    limit: nil,
                    keys: keys
                )
            )
            return response.items.compactMap { item -> ProjectDocument? in
                guard item.ok,
                      let b64 = item.plaintext,
                      let plaintext = Data(base64Encoded: b64),
                      let decoded = try? JSONDecoder().decode(ProjectDocumentPayload.self, from: plaintext) else {
                    return nil
                }
                let docId = documentIdFromWireId(item.id)
                let updateMatch = scoped.first(where: { $0.id == item.id })
                return ProjectDocument(
                    id: docId,
                    projectId: projectId,
                    filename: decoded.filename,
                    contentType: decoded.contentType,
                    sizeBytes: decoded.content.data(using: .utf8)?.count ?? decoded.content.count,
                    syncVersion: etagToSyncVersion(updateMatch?.etag),
                    createdAt: createdAtFromReverseId(docId),
                    updatedAt: updateMatch?.updatedAt ?? isoNow(),
                    content: decoded.content
                )
            }
        }

        return scoped.map { update in
            let docId = documentIdFromWireId(update.id)
            return ProjectDocument(
                id: docId,
                projectId: projectId,
                filename: "",
                contentType: "",
                sizeBytes: 0,
                syncVersion: etagToSyncVersion(update.etag),
                createdAt: createdAtFromReverseId(docId),
                updatedAt: update.updatedAt,
                content: nil
            )
        }
    }

    func deleteDocument(projectId: String, documentId: String) async throws {
        let keyB64 = try CEKEncoding.requirePrimaryKeyB64()
        let wireId = projectDocumentId(projectId: projectId, documentId: documentId)
        _ = try await SyncEnclaveAPI.deleteRow(
            EnclaveDeleteRequest(
                scope: .projectDocument,
                id: wireId,
                ifMatch: nil,
                idempotencyKey: newSyncEnclaveIdempotencyKey(),
                key: keyB64
            )
        )
    }

    func getDocumentSyncStatus(projectId: String) async throws -> ProjectDocumentSyncStatus {
        let documents = try await listDocuments(projectId: projectId, includeContent: false)
        let lastUpdated = documents.reduce(into: nil as String?) { acc, doc in
            if let prev = acc {
                if doc.updatedAt > prev { acc = doc.updatedAt }
            } else {
                acc = doc.updatedAt
            }
        }
        return ProjectDocumentSyncStatus(count: documents.count, lastUpdated: lastUpdated)
    }

    // MARK: - Helpers

    private func projectDocumentId(projectId: String, documentId: String) -> String {
        return "\(projectId)/\(documentId)"
    }

    private func documentIdFromWireId(_ wireId: String) -> String {
        if let slash = wireId.firstIndex(of: "/") {
            return String(wireId[wireId.index(after: slash)...])
        }
        return wireId
    }

    private func etagToSyncVersion(_ etag: String?) -> Int {
        guard let etag, let value = Int(etag), value > 0 else { return 1 }
        return value
    }

    private func hasNextCursor(_ cursor: String?) -> Bool {
        guard let cursor else { return false }
        return !cursor.isEmpty
    }

    private func createdAtFromReverseId(_ id: String) -> String {
        guard let prefix = id.split(separator: "_").first,
              let reverse = Int(prefix) else {
            return isoNow()
        }
        let ms = Constants.Sync.maxReverseTimestamp - reverse
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return iso8601.string(from: date)
    }

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func isoNow() -> String { iso8601.string(from: Date()) }
}
