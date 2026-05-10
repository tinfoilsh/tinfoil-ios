//
//  ProjectStorageService.swift
//  TinfoilChat
//
//  Cloud storage API for webapp-compatible Projects.
//

import Foundation
import ClerkKit

final class ProjectStorageService: ObservableObject {
    static let shared = ProjectStorageService()

    private let apiBaseURL = Constants.API.baseURL
    private var getToken: (() async -> String?)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    func setTokenGetter(_ tokenGetter: @escaping () async -> String?) {
        self.getToken = tokenGetter
    }

    func isAuthenticated() async -> Bool {
        let token = await (getToken ?? defaultTokenGetter)()
        return token?.isEmpty == false
    }

    private func defaultTokenGetter() async -> String? {
        do {
            guard await !Clerk.shared.publishableKey.isEmpty else {
                return nil
            }

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

    private func getHeaders(contentType: String = "application/json") async throws -> [String: String] {
        guard let token = await (getToken ?? defaultTokenGetter)(), !token.isEmpty else {
            throw CloudStorageError.authenticationRequired
        }

        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": contentType
        ]
    }

    private func performJSONRequest<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw CloudStorageError.invalidResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    private func performEmptyRequest(_ request: URLRequest, acceptedStatusCodes: Set<Int> = [200]) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              acceptedStatusCodes.contains(httpResponse.statusCode) else {
            throw CloudStorageError.invalidResponse
        }
    }

    func generateProjectId() async throws -> GenerateProjectIdResponse {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/projects/generate-id")!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await getHeaders()
        return try await performJSONRequest(request, as: GenerateProjectIdResponse.self)
    }

    func createProject(_ data: CreateProjectData) async throws -> Project {
        let idResponse = try await generateProjectId()
        let payload = ProjectData(
            name: data.name,
            description: data.description,
            systemInstructions: data.systemInstructions,
            memory: []
        )
        let encrypted = try await EncryptionService.shared.encrypt(payload)
        let encryptedString = String(data: try encoder.encode(encrypted), encoding: .utf8) ?? "{}"

        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/storage/project")!)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = try await getHeaders()
        request.httpBody = try encoder.encode(ProjectUpsertRequest(projectId: idResponse.projectId, data: encryptedString))

        let response = try await performJSONRequest(request, as: ProjectUpsertResponse.self)
        return Project(
            id: idResponse.projectId,
            name: payload.name,
            description: payload.description,
            systemInstructions: payload.systemInstructions,
            memory: payload.memory,
            createdAt: response.createdAt,
            updatedAt: response.updatedAt,
            syncVersion: response.syncVersion
        )
    }

    func updateProject(_ projectId: String, data: UpdateProjectData) async throws {
        guard let existing = try await getProject(projectId) else {
            throw CloudStorageError.invalidResponse
        }

        let payload = ProjectData(
            name: data.name ?? existing.name,
            description: data.description ?? existing.description,
            systemInstructions: data.systemInstructions ?? existing.systemInstructions,
            memory: data.memory ?? existing.memory
        )
        let encrypted = try await EncryptionService.shared.encrypt(payload)
        let encryptedString = String(data: try encoder.encode(encrypted), encoding: .utf8) ?? "{}"

        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/storage/project")!)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = try await getHeaders()
        request.httpBody = try encoder.encode(ProjectUpsertRequest(projectId: projectId, data: encryptedString))

        try await performEmptyRequest(request)
    }

    func getProject(_ projectId: String) async throws -> Project? {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/storage/project/\(projectId)")!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudStorageError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            return nil
        }
        guard httpResponse.statusCode == 200 else {
            throw CloudStorageError.downloadFailed
        }

        let item = try decoder.decode(ProjectStorageItem.self, from: data)
        let encrypted = item.content.encryptedData
        let decryptionResult = try await EncryptionService.shared.decrypt(encrypted, as: ProjectData.self)
        let projectData = decryptionResult.value

        return Project(
            id: projectId,
            name: projectData.name,
            description: projectData.description,
            systemInstructions: projectData.systemInstructions,
            memory: projectData.memory,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            syncVersion: item.syncVersion
        )
    }

    func deleteProject(_ projectId: String) async throws {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/storage/project/\(projectId)")!)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = try await getHeaders()
        try await performEmptyRequest(request, acceptedStatusCodes: [200, 404])
    }

    func listProjects(limit: Int = Constants.Pagination.projectsPerPage, continuationToken: String? = nil, includeContent: Bool = true) async throws -> ProjectListResponse {
        var components = URLComponents(string: "\(apiBaseURL)/api/projects")!
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if includeContent {
            queryItems.append(URLQueryItem(name: "includeContent", value: "true"))
        }
        if let continuationToken {
            queryItems.append(URLQueryItem(name: "continuationToken", value: continuationToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()
        return try await performJSONRequest(request, as: ProjectListResponse.self)
    }

    func loadProjects(limit: Int = Constants.Pagination.projectsPerPage) async throws -> [Project] {
        var allItems: [ProjectListItem] = []
        var continuationToken: String? = nil

        repeat {
            let response = try await listProjects(
                limit: limit,
                includeContent: true,
                continuationToken: continuationToken
            )
            allItems.append(contentsOf: response.projects)
            let nextToken = response.nextContinuationToken?.isEmpty == false ? response.nextContinuationToken : nil
            continuationToken = response.hasMore ? nextToken : nil
        } while continuationToken != nil

        return try await allItems.asyncMap { item in
            guard let content = item.content else {
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

            do {
                let encrypted = try decodeEncryptedData(from: content)
                let decryptionResult = try await EncryptionService.shared.decrypt(encrypted, as: ProjectData.self)
                let projectData = decryptionResult.value
                return Project(
                    id: item.id,
                    name: projectData.name,
                    description: projectData.description,
                    systemInstructions: projectData.systemInstructions,
                    memory: projectData.memory,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    syncVersion: item.syncVersion
                )
            } catch {
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
    }

    func generateDocumentId(projectId: String) async throws -> GenerateDocumentIdResponse {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/projects/\(projectId)/documents/generate-id")!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await getHeaders()
        return try await performJSONRequest(request, as: GenerateDocumentIdResponse.self)
    }

    func uploadDocument(projectId: String, filename: String, contentType: String, content: String) async throws -> ProjectDocument {
        let idResponse = try await generateDocumentId(projectId: projectId)
        let payload = ProjectDocumentPayload(content: content, filename: filename, contentType: contentType)
        let encrypted = try await EncryptionService.shared.encrypt(payload)
        let encryptedString = String(data: try encoder.encode(encrypted), encoding: .utf8) ?? "{}"

        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/projects/\(projectId)/documents")!)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = try await getHeaders()
        request.httpBody = try encoder.encode(ProjectDocumentUpsertRequest(documentId: idResponse.documentId, data: encryptedString))

        let response = try await performJSONRequest(request, as: ProjectDocumentUpsertResponse.self)
        return ProjectDocument(
            id: idResponse.documentId,
            projectId: projectId,
            filename: filename,
            contentType: contentType,
            sizeBytes: content.data(using: .utf8)?.count ?? content.count,
            syncVersion: response.syncVersion,
            createdAt: response.createdAt,
            updatedAt: response.updatedAt,
            content: content
        )
    }

    func listDocuments(projectId: String, includeContent: Bool = true) async throws -> [ProjectDocument] {
        var components = URLComponents(string: "\(apiBaseURL)/api/projects/\(projectId)/documents")!
        if includeContent {
            components.queryItems = [URLQueryItem(name: "includeContent", value: "true")]
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await getHeaders()
        let response = try await performJSONRequest(request, as: ProjectDocumentListResponse.self)

        return try await response.documents.asyncMap { item in
            if includeContent, let content = item.content {
                do {
                    let encrypted = try decodeEncryptedData(from: content)
                    let decryptionResult = try await EncryptionService.shared.decrypt(encrypted, as: ProjectDocumentPayload.self)
                    let payload = decryptionResult.value
                    return ProjectDocument(
                        id: item.id,
                        projectId: item.projectId,
                        filename: payload.filename,
                        contentType: payload.contentType,
                        sizeBytes: item.sizeBytes ?? (payload.content.data(using: .utf8)?.count ?? payload.content.count),
                        syncVersion: item.syncVersion,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt,
                        content: payload.content
                    )
                } catch {
                    return ProjectDocument(
                        id: item.id,
                        projectId: item.projectId,
                        filename: "Encrypted",
                        contentType: "",
                        sizeBytes: item.sizeBytes ?? 0,
                        syncVersion: item.syncVersion,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt,
                        content: nil
                    )
                }
            }

            return ProjectDocument(
                id: item.id,
                projectId: item.projectId,
                filename: "",
                contentType: "",
                sizeBytes: item.sizeBytes ?? 0,
                syncVersion: item.syncVersion,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                content: nil
            )
        }
    }

    func deleteDocument(projectId: String, documentId: String) async throws {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/projects/\(projectId)/documents/\(documentId)")!)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = try await getHeaders()
        try await performEmptyRequest(request, acceptedStatusCodes: [200, 404])
    }

    private func decodeEncryptedData(from string: String) throws -> EncryptedData {
        guard let data = string.data(using: .utf8) else {
            throw CloudStorageError.decryptionFailed
        }
        return try decoder.decode(EncryptedData.self, from: data)
    }
}

private struct ProjectUpsertRequest: Codable {
    let projectId: String
    let data: String
}

private struct ProjectDocumentUpsertRequest: Codable {
    let documentId: String
    let data: String
}

private struct ProjectUpsertResponse: Codable {
    let createdAt: String
    let updatedAt: String
    let syncVersion: Int
}

private struct ProjectDocumentUpsertResponse: Codable {
    let createdAt: String
    let updatedAt: String
    let syncVersion: Int
}

private struct ProjectStorageItem: Codable {
    let createdAt: String
    let updatedAt: String
    let syncVersion: Int
    let content: EncryptedProjectContent
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
    }
}
