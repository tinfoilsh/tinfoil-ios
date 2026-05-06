//
//  LinkMetadataService.swift
//  TinfoilChat
//
//  Fetches OpenGraph metadata (title/description/site_name/image/favicon)
//  for a URL from the `opengraph-metadata.tinfoil.sh` endpoint. Mirrors the
//  webapp's `metadata-client.ts` so the iOS link-preview widget surfaces
//  the same rich card (hero image + favicon + title + description) as the
//  web build.
//
//  In-flight requests for the same URL are deduplicated so multiple
//  `LinkPreviewView` instances rendering the same link share a single
//  network round-trip.

import Foundation

struct LinkMetadata: Equatable, Sendable {
    let url: String
    let title: String?
    let description: String?
    let siteName: String?
    let image: String?
    let favicon: String?
    let cached: Bool
}

private struct MetadataResponse: Decodable {
    let url: String
    let title: String?
    let description: String?
    let site_name: String?
    let image: String?
    let favicon: String?
    let cached: Bool?
}

enum LinkMetadataError: Error {
    case invalidURL
    case badStatus(Int)
    case decodingFailed
}

actor LinkMetadataService {
    static let shared = LinkMetadataService()

    private static let endpoint = URL(string: "https://opengraph-metadata.tinfoil.sh/metadata")!

    private var cache: [String: LinkMetadata] = [:]
    private var inFlight: [String: Task<LinkMetadata, Error>] = [:]

    func metadata(for url: String) async throws -> LinkMetadata {
        if let cached = cache[url] { return cached }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<LinkMetadata, Error> { [endpoint = LinkMetadataService.endpoint] in
            try await Self.fetch(url: url, endpoint: endpoint)
        }
        inFlight[url] = task

        defer { inFlight[url] = nil }
        let result = try await task.value
        cache[url] = result
        return result
    }

    private static func fetch(url: String, endpoint: URL) async throws -> LinkMetadata {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": url])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LinkMetadataError.badStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LinkMetadataError.badStatus(http.statusCode)
        }
        do {
            let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)
            return LinkMetadata(
                url: decoded.url,
                title: decoded.title,
                description: decoded.description,
                siteName: decoded.site_name,
                image: decoded.image,
                favicon: decoded.favicon,
                cached: decoded.cached ?? false
            )
        } catch {
            throw LinkMetadataError.decodingFailed
        }
    }
}
