//
//  LinkMetadataService.swift
//  TinfoilChat
//
//  Fetches OpenGraph metadata (title/description/site_name/image/favicon)
//  for a URL from the `opengraph-metadata.tinfoil.sh` enclave through an
//  attested `SecureClient`. Mirrors the webapp's `metadata-client.ts` so
//  the iOS link-preview widget surfaces the same rich card (hero image
//  + favicon + title + description) as the web build.
//
//  In-flight requests for the same URL are deduplicated so multiple
//  `LinkPreviewView` instances rendering the same link share a single
//  network round-trip.

import Foundation
import TinfoilAI

struct LinkMetadata: Equatable, Sendable {
    let url: String
    let title: String?
    let description: String?
    let siteName: String?
    let image: String?
    let faviconBytes: Data?
    let faviconContentType: String?
    let cached: Bool
}

private struct MetadataRequest: Encodable {
    let url: String
}

private struct MetadataResponse: Decodable {
    let url: String
    let title: String?
    let description: String?
    let site_name: String?
    let image: String?
    let favicon_bytes: Data?
    let favicon_content_type: String?
    let cached: Bool?
}

enum LinkMetadataError: Error {
    case invalidURL
    case badStatus(Int)
    case decodingFailed
}

actor LinkMetadataService {
    static let shared = LinkMetadataService()

    private var cache: [String: LinkMetadata] = [:]
    private var inFlight: [String: Task<LinkMetadata, Error>] = [:]

    private var client: SecureClient?
    private var verificationTask: Task<SecureClient, Error>?

    private init() {}

    private func getClient() async throws -> SecureClient {
        if let client = client {
            return client
        }

        if let existingTask = verificationTask {
            return try await existingTask.value
        }

        let task = Task<SecureClient, Error> {
            let newClient = SecureClient(
                githubRepo: Constants.Metadata.configRepo,
                enclaveURL: Constants.Metadata.enclaveURL
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

    func metadata(for url: String) async throws -> LinkMetadata {
        if let cached = cache[url] { return cached }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<LinkMetadata, Error> { [weak self] in
            guard let self = self else { throw LinkMetadataError.invalidURL }
            return try await self.fetch(url: url)
        }
        inFlight[url] = task

        defer { inFlight[url] = nil }
        let result = try await task.value
        cache[url] = result
        return result
    }

    private func fetch(url: String) async throws -> LinkMetadata {
        let client = try await getClient()
        let body = try JSONEncoder().encode(MetadataRequest(url: url))

        let response = try await client.post(
            url: "\(Constants.Metadata.enclaveURL)/metadata",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        guard (200..<300).contains(response.statusCode) else {
            throw LinkMetadataError.badStatus(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(MetadataResponse.self, from: response.body)
            return LinkMetadata(
                url: decoded.url,
                title: decoded.title,
                description: decoded.description,
                siteName: decoded.site_name,
                image: decoded.image,
                faviconBytes: decoded.favicon_bytes,
                faviconContentType: decoded.favicon_content_type,
                cached: decoded.cached ?? false
            )
        } catch {
            throw LinkMetadataError.decodingFailed
        }
    }
}
