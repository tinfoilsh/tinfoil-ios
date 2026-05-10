//
//  DocumentConversionService.swift
//  TinfoilChat
//
//  Attested document conversion for project context uploads.
//

import Foundation
import TinfoilAI
import UniformTypeIdentifiers

actor DocumentConversionService {
    static let shared = DocumentConversionService()

    private var client: SecureClient?
    private var verificationTask: Task<SecureClient, Error>?
    private let decoder = JSONDecoder()

    private init() {}

    private func getClient() async throws -> SecureClient {
        if let client {
            return client
        }

        if let verificationTask {
            return try await verificationTask.value
        }

        let task = Task<SecureClient, Error> {
            let newClient = SecureClient(
                githubRepo: Constants.DocumentProcessing.configRepo,
                enclaveURL: Constants.DocumentProcessing.enclaveURL
            )
            _ = try await newClient.verify()
            return newClient
        }
        verificationTask = task

        do {
            let verifiedClient = try await task.value
            client = verifiedClient
            verificationTask = nil
            return verifiedClient
        } catch {
            verificationTask = nil
            throw error
        }
    }

    func convertToMarkdown(url: URL, filename: String, contentType: String? = nil, mode: String = Constants.DocumentProcessing.defaultMode) async throws -> String {
        let fileData = try Data(contentsOf: url)
        let boundary = "Boundary-\(UUID().uuidString)"
        let mimeType = contentType ?? Self.mimeType(for: filename)
        let body = Self.multipartBody(
            boundary: boundary,
            fileData: fileData,
            filename: filename,
            contentType: mimeType
        )

        guard var components = URLComponents(string: "\(Constants.DocumentProcessing.enclaveURL)\(Constants.DocumentProcessing.convertPath)") else {
            throw DocumentConversionError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "mode", value: mode)]

        let apiKey = await SessionTokenManager.shared.getSessionToken()
        guard !apiKey.isEmpty else {
            throw DocumentConversionError.missingAPIKey
        }

        let client = try await getClient()
        let response = try await client.post(
            url: components.url?.absoluteString ?? "\(Constants.DocumentProcessing.enclaveURL)\(Constants.DocumentProcessing.convertPath)",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "multipart/form-data; boundary=\(boundary)"
            ],
            body: body
        )

        guard response.statusCode == 200 else {
            throw DocumentConversionError.requestFailed(statusCode: response.statusCode)
        }

        let decoded = try decoder.decode(DocumentConversionResponse.self, from: response.body)
        if let mdContent = decoded.document?.mdContent {
            return mdContent
        }
        if let mdContent = decoded.documents?.first?.mdContent {
            return mdContent
        }
        throw DocumentConversionError.invalidResponse
    }

    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        switch ext.lowercased() {
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }

    private static func multipartBody(boundary: String, fileData: Data, filename: String, contentType: String) -> Data {
        var body = Data()
        let safeFilename = sanitizeMultipartHeaderValue(filename)
        let safeContentType = sanitizeMultipartHeaderValue(contentType)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"files\"; filename=\"\(safeFilename)\"\r\n")
        body.appendString("Content-Type: \(safeContentType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func sanitizeMultipartHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

private struct DocumentConversionResponse: Codable {
    let document: ConvertedDocument?
    let documents: [ConvertedDocument]?
    let status: String?
    let processingTime: Double?

    enum CodingKeys: String, CodingKey {
        case document, documents, status
        case processingTime = "processing_time"
    }
}

private struct ConvertedDocument: Codable {
    let mdContent: String?

    enum CodingKeys: String, CodingKey {
        case mdContent = "md_content"
    }
}

enum DocumentConversionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Could not get a Tinfoil session key."
        case .invalidResponse:
            return "Document conversion returned an invalid response."
        case .requestFailed(let statusCode):
            return "Document conversion failed with status \(statusCode)."
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
