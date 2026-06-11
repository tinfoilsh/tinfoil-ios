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

    private let enclaveStore = SyncEnclaveProjectStore()
    private let projectListLimit = Constants.SyncEnclave.projectListLimit
    private var getToken: (() async -> String?)? = nil

    private init() {}

    // MARK: - Configuration

    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) async {
        self.getToken = tokenGetter
        let captured = tokenGetter
        await SyncEnclaveClient.shared.setTokenGetter { await captured() }
    }

    private func defaultTokenGetter() async -> String? {
        do {
            guard await !Clerk.shared.publishableKey.isEmpty else { return nil }
            if await !Clerk.shared.isLoaded {
                try await Clerk.shared.refreshClient()
            }
            if let session = await Clerk.shared.session {
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
        let idResponse = try await generateProjectId()
        let (payload, syncVersion) = try await enclaveStore.createProject(id: idResponse.projectId, data: data)
        let now = isoNow()
        return Project(
            id: idResponse.projectId,
            name: payload.name,
            description: payload.description,
            systemInstructions: payload.systemInstructions,
            memory: payload.memory,
            createdAt: now,
            updatedAt: now,
            syncVersion: syncVersion
        )
    }

    func updateProject(_ projectId: String, data: UpdateProjectData) async throws {
        guard let existing = try await getProject(projectId) else {
            throw CloudStorageError.invalidResponse
        }
        try await enclaveStore.updateProject(id: projectId, data: data, existing: existing)
    }

    func getProject(_ projectId: String) async throws -> Project? {
        guard let (decoded, syncVersion) = try await enclaveStore.getProject(id: projectId) else { return nil }
        let now = isoNow()
        return Project(
            id: projectId,
            name: decoded.name,
            description: decoded.description,
            systemInstructions: decoded.systemInstructions,
            memory: decoded.memory,
            createdAt: now,
            updatedAt: now,
            syncVersion: syncVersion
        )
    }

    func getProjects(_ projectIds: [String]) async throws -> [String: Project] {
        guard !projectIds.isEmpty else { return [:] }
        let decodedProjects = try await enclaveStore.getProjects(ids: projectIds)
        var out: [String: Project] = [:]
        for (id, decoded) in decodedProjects {
            let now = isoNow()
            out[id] = Project(
                id: id,
                name: decoded.0.name,
                description: decoded.0.description,
                systemInstructions: decoded.0.systemInstructions,
                memory: decoded.0.memory,
                createdAt: now,
                updatedAt: now,
                syncVersion: decoded.1
            )
        }
        return out
    }

    func deleteProject(_ projectId: String) async throws {
        try await enclaveStore.deleteProject(id: projectId)
    }

    @discardableResult
    func deleteAllProjects() async throws -> Int {
        try await enclaveStore.deleteAllProjects()
    }

    func listProjects(
        limit: Int = Constants.Pagination.projectsPerPage,
        continuationToken: String? = nil,
        includeContent: Bool = true
    ) async throws -> ProjectListResponse {
        let pageLimit = min(limit, Constants.SyncEnclave.listStatusPageLimit)
        let status = try await SyncEnclaveAPI.listStatus(
            EnclaveListStatusRequest(
                scope: .project,
                cursor: continuationToken,
                limit: pageLimit,
                projectId: nil,
                direction: "desc"
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
        // Let a failed batch fetch propagate: swallowing it here would
        // dress every project up as a decrypt-failed placeholder when
        // the real problem was network or auth.
        let projects = try await getProjects(ids)
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
                EnclaveListStatusRequest(scope: .project, cursor: cursor, limit: Constants.SyncEnclave.listStatusPageLimit, projectId: nil)
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
        let idResponse = try await generateDocumentId(projectId: projectId)
        let wireId = projectDocumentId(projectId: projectId, documentId: idResponse.documentId)
        let (payload, syncVersion) = try await enclaveStore.uploadDocument(
            id: wireId,
            projectId: projectId,
            filename: filename,
            contentType: contentType,
            content: content
        )

        let now = isoNow()
        let size = payload.content.data(using: .utf8)?.count ?? payload.content.count
        return ProjectDocument(
            id: idResponse.documentId,
            projectId: projectId,
            filename: payload.filename,
            contentType: payload.contentType,
            sizeBytes: size,
            syncVersion: syncVersion,
            createdAt: now,
            updatedAt: now,
            content: payload.content
        )
    }

    func getDocument(projectId: String, documentId: String) async throws -> ProjectDocument? {
        let wireId = projectDocumentId(projectId: projectId, documentId: documentId)
        guard let (decoded, syncVersion) = try await enclaveStore.getDocument(id: wireId) else { return nil }
        let now = isoNow()
        return ProjectDocument(
            id: documentId,
            projectId: projectId,
            filename: decoded.filename,
            contentType: decoded.contentType,
            sizeBytes: decoded.content.data(using: .utf8)?.count ?? decoded.content.count,
            syncVersion: syncVersion,
            createdAt: now,
            updatedAt: now,
            content: decoded.content
        )
    }

    func listDocuments(projectId: String, includeContent: Bool = true) async throws -> [ProjectDocument] {
        var status = try await SyncEnclaveAPI.listStatus(
            EnclaveListStatusRequest(scope: .projectDocument, cursor: nil, limit: Constants.SyncEnclave.listStatusPageLimit, projectId: nil)
        )
        var allUpdates = status.updates
        while hasNextCursor(status.nextCursor) {
            status = try await SyncEnclaveAPI.listStatus(
                EnclaveListStatusRequest(
                    scope: .projectDocument,
                    cursor: status.nextCursor,
                    limit: Constants.SyncEnclave.listStatusPageLimit,
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
            let documents = try await enclaveStore.getDocuments(ids: ids)
            return scoped.map { update -> ProjectDocument in
                let docId = documentIdFromWireId(update.id)
                guard let decoded = documents[update.id] else {
                    // Surface the row as a decrypt-failed placeholder so
                    // the UI can render it and the user can take action
                    // (retry with another key, delete it, etc.) instead
                    // of silently dropping the document.
                    return ProjectDocument(
                        id: docId,
                        projectId: projectId,
                        filename: "",
                        contentType: "",
                        sizeBytes: 0,
                        syncVersion: etagToSyncVersion(update.etag),
                        createdAt: createdAtFromReverseId(docId),
                        updatedAt: update.updatedAt,
                        content: nil,
                        decryptionFailed: true
                    )
                }
                return ProjectDocument(
                    id: docId,
                    projectId: projectId,
                    filename: decoded.0.filename,
                    contentType: decoded.0.contentType,
                    sizeBytes: decoded.0.content.data(using: .utf8)?.count ?? decoded.0.content.count,
                    syncVersion: decoded.1,
                    createdAt: createdAtFromReverseId(docId),
                    updatedAt: update.updatedAt,
                    content: decoded.0.content,
                    decryptionFailed: false
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
                content: nil,
                decryptionFailed: false
            )
        }
    }

    func deleteDocument(projectId: String, documentId: String) async throws {
        let wireId = projectDocumentId(projectId: projectId, documentId: documentId)
        try await enclaveStore.deleteDocument(id: wireId)
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
