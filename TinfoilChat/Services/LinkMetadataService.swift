//
//  LinkMetadataService.swift
//  TinfoilChat
//
//  Fetches OpenGraph metadata and favicons
//  for a URL from the `opengraph-metadata.tinfoil.sh` enclave through an
//  attested `EnclaveHandle`. Mirrors the webapp's `metadata-client.ts` so
//  the iOS link-preview widget surfaces the same rich card as the web build.
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
    let cached: Bool?
}

private struct FaviconResponse: Decodable {
    let favicon_bytes: Data
}

enum LinkMetadataError: Error {
    case invalidURL
    case badStatus(Int)
    case decodingFailed
}

actor LinkMetadataService {
    static let shared = LinkMetadataService()

    private var cache: [String: LinkMetadata] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LinkMetadata, Error>] = [:]
    private var faviconCache: [String: Data] = [:]
    private var faviconCacheOrder: [String] = []
    private var faviconInFlight: [String: Task<Data, Error>] = [:]

    private var handle: EnclaveHandle?

    private init() {}

    /// The metadata enclave's handle, which verifies on first use and again
    /// whenever its attestation expires
    private func enclaveHandle() throws -> EnclaveHandle {
        if let handle {
            return handle
        }
        let created = try EnclaveHandle.enclave(
            at: Constants.Metadata.enclaveURL,
            repo: Constants.Metadata.configRepo
        )
        handle = created
        return created
    }

    func metadata(for url: String) async throws -> LinkMetadata {
        if let cached = cache[url] { return cached }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<LinkMetadata, Error> {
            try await self.fetch(url: url)
        }
        inFlight[url] = task

        defer { inFlight[url] = nil }
        let result = try await task.value
        storeInCache(result, for: url)
        return result
    }

    func favicon(for url: String) async throws -> Data {
        guard let host = URL(string: url)?.host?.lowercased() else {
            throw LinkMetadataError.invalidURL
        }
        if let cached = faviconCache[host] { return cached }
        if let existing = faviconInFlight[host] { return try await existing.value }

        let task = Task<Data, Error> {
            try await self.fetchFavicon(url: url)
        }
        faviconInFlight[host] = task

        defer { faviconInFlight[host] = nil }
        let result = try await task.value
        storeFaviconInCache(result, for: host)
        return result
    }

    private func storeInCache(_ metadata: LinkMetadata, for url: String) {
        if cache[url] == nil {
            cacheOrder.append(url)
        }
        cache[url] = metadata
        while cacheOrder.count > Constants.Metadata.cacheEntryLimit {
            let evicted = cacheOrder.removeFirst()
            cache[evicted] = nil
        }
    }

    private func storeFaviconInCache(_ favicon: Data, for host: String) {
        if faviconCache[host] == nil {
            faviconCacheOrder.append(host)
        }
        faviconCache[host] = favicon
        while faviconCacheOrder.count > Constants.Metadata.cacheEntryLimit {
            let evicted = faviconCacheOrder.removeFirst()
            faviconCache[evicted] = nil
        }
    }

    private func fetch(url: String) async throws -> LinkMetadata {
        let enclave = try enclaveHandle()
        let body = try JSONEncoder().encode(MetadataRequest(url: url))

        let (data, response) = try await enclave.post(
            url: "\(Constants.Metadata.enclaveURL)/metadata",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        guard (200..<300).contains(response.statusCode) else {
            throw LinkMetadataError.badStatus(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)
            return LinkMetadata(
                url: decoded.url,
                title: decoded.title,
                description: decoded.description,
                siteName: decoded.site_name,
                image: decoded.image,
                cached: decoded.cached ?? false
            )
        } catch {
            throw LinkMetadataError.decodingFailed
        }
    }

    private func fetchFavicon(url: String) async throws -> Data {
        let enclave = try enclaveHandle()
        let body = try JSONEncoder().encode(MetadataRequest(url: url))
        let (data, response) = try await enclave.post(
            url: "\(Constants.Metadata.enclaveURL)/favicon",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        guard (200..<300).contains(response.statusCode) else {
            throw LinkMetadataError.badStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(FaviconResponse.self, from: data).favicon_bytes
        } catch {
            throw LinkMetadataError.decodingFailed
        }
    }
}
