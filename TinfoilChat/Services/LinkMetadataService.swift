//
//  LinkMetadataService.swift
//  TinfoilChat
//
//  Fetches OpenGraph metadata and favicons
//  for a URL from the `opengraph-metadata.tinfoil.sh` enclave through an
//  attested `SecureClient`. Mirrors the webapp's `metadata-client.ts` so
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
    let siteName: String?
    let image: String?
    let cached: Bool?

    enum CodingKeys: String, CodingKey {
        case url, title, description, image, cached
        case siteName = "site_name"
    }
}

private struct FaviconResponse: Decodable {
    let faviconBytes: Data?
    let found: Bool?
    let missing: Bool?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case found, missing, status
        case faviconBytes = "favicon_bytes"
    }

    var isMissing: Bool {
        missing == true || found == false || status == "missing"
    }
}

enum LinkMetadataError: Error, Equatable {
    case invalidURL
    case badStatus(Int)
    case decodingFailed
    case invalidPayload
    case faviconMissing
    case cooldownActive
}

actor LinkMetadataService {
    static let shared = LinkMetadataService()

    private struct Timed<Value> {
        let value: Value
        let expiresAt: Date
    }

    private enum FaviconValue {
        case found(Data)
        case missing
    }

    private struct FailureState {
        let count: Int
        let retryAfter: Date
    }

    private var cache: [String: Timed<LinkMetadata>] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LinkMetadata, Error>] = [:]
    private var faviconCache: [String: Timed<FaviconValue>] = [:]
    private var faviconCacheOrder: [String] = []
    private var faviconInFlight: [String: Task<Data, Error>] = [:]
    private var failures: [String: FailureState] = [:]
    private var failureOrder: [String] = []

    private var client: SecureClient?
    private var verificationTask: Task<SecureClient, Error>?
    private var lifecycleGeneration = 0

    private init() {}

    func reset() {
        lifecycleGeneration += 1
        verificationTask?.cancel()
        verificationTask = nil
        client = nil
        inFlight.values.forEach { $0.cancel() }
        faviconInFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        faviconInFlight.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        faviconCache.removeAll()
        faviconCacheOrder.removeAll()
        failures.removeAll()
        failureOrder.removeAll()
    }

    private func getClient() async throws -> SecureClient {
        if let client { return client }
        if let verificationTask { return try await verificationTask.value }

        let generation = lifecycleGeneration
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
            guard generation == lifecycleGeneration else { throw CancellationError() }
            client = verifiedClient
            verificationTask = nil
            return verifiedClient
        } catch {
            if generation == lifecycleGeneration {
                verificationTask = nil
            }
            throw error
        }
    }

    func metadata(for url: String) async throws -> LinkMetadata {
        let key = try Self.canonicalURL(url)
        let now = Date()
        if let cached = cache[key], cached.expiresAt > now { return cached.value }
        cache[key] = nil
        cacheOrder.removeAll { $0 == key }
        try enforceCooldown(for: "metadata:\(key)", now: now)
        if let existing = inFlight[key] { return try await existing.value }

        let generation = lifecycleGeneration
        let task = Task<LinkMetadata, Error> { try await self.fetch(url: key) }
        inFlight[key] = task
        defer {
            if generation == lifecycleGeneration { inFlight[key] = nil }
        }
        do {
            let result = try await task.value
            guard generation == lifecycleGeneration else { throw CancellationError() }
            let completedAt = Date()
            clearFailure(for: "metadata:\(key)")
            storeInCache(result, for: key, now: completedAt)
            return result
        } catch {
            if generation == lifecycleGeneration {
                recordFailure(error, for: "metadata:\(key)", now: Date())
            }
            throw error
        }
    }

    func favicon(for url: String) async throws -> Data {
        let canonicalURL = try Self.canonicalURL(url)
        guard let host = URL(string: canonicalURL)?.host?.lowercased() else {
            throw LinkMetadataError.invalidURL
        }
        let now = Date()
        if let cached = faviconCache[host], cached.expiresAt > now {
            switch cached.value {
            case .found(let data): return data
            case .missing: throw LinkMetadataError.faviconMissing
            }
        }
        faviconCache[host] = nil
        faviconCacheOrder.removeAll { $0 == host }
        try enforceCooldown(for: "favicon:\(host)", now: now)
        if let existing = faviconInFlight[host] { return try await existing.value }

        let generation = lifecycleGeneration
        let task = Task<Data, Error> { try await self.fetchFavicon(url: canonicalURL) }
        faviconInFlight[host] = task
        defer {
            if generation == lifecycleGeneration { faviconInFlight[host] = nil }
        }
        do {
            let result = try await task.value
            guard generation == lifecycleGeneration else { throw CancellationError() }
            let completedAt = Date()
            clearFailure(for: "favicon:\(host)")
            storeFaviconInCache(.found(result), for: host, now: completedAt)
            return result
        } catch LinkMetadataError.faviconMissing {
            guard generation == lifecycleGeneration else { throw CancellationError() }
            clearFailure(for: "favicon:\(host)")
            storeFaviconInCache(.missing, for: host, now: Date())
            throw LinkMetadataError.faviconMissing
        } catch {
            if generation == lifecycleGeneration {
                recordFailure(error, for: "favicon:\(host)", now: Date())
            }
            throw error
        }
    }

    private func enforceCooldown(for key: String, now: Date) throws {
        if let failure = failures[key], failure.retryAfter > now {
            throw LinkMetadataError.cooldownActive
        }
    }

    private func recordFailure(_ error: Error, for key: String, now: Date) {
        if error is CancellationError { return }
        if let metadataError = error as? LinkMetadataError {
            switch metadataError {
            case .invalidURL, .faviconMissing, .cooldownActive:
                return
            default:
                break
            }
        }
        let count = (failures[key]?.count ?? 0) + 1
        let delay = Self.transientCooldown(failureCount: count)
        if failures[key] == nil { failureOrder.append(key) }
        failures[key] = FailureState(count: count, retryAfter: now.addingTimeInterval(delay))
        while failureOrder.count > Constants.Metadata.cacheEntryLimit {
            failures[failureOrder.removeFirst()] = nil
        }
    }

    private func clearFailure(for key: String) {
        failures[key] = nil
        failureOrder.removeAll { $0 == key }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case LinkMetadataError.badStatus(let status) = error {
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
        return URLErrorClassifier.isConnectivityFailure(error)
    }

    static func transientCooldown(failureCount: Int) -> TimeInterval {
        min(
            Constants.Metadata.transientCooldownSeconds * pow(2, Double(max(0, failureCount - 1))),
            Constants.Metadata.maximumTransientCooldownSeconds
        )
    }

    private func storeInCache(_ metadata: LinkMetadata, for url: String, now: Date) {
        if cache[url] == nil { cacheOrder.append(url) }
        cache[url] = Timed(
            value: metadata,
            expiresAt: now.addingTimeInterval(Constants.Metadata.metadataCacheSeconds)
        )
        while cacheOrder.count > Constants.Metadata.cacheEntryLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func storeFaviconInCache(_ favicon: FaviconValue, for host: String, now: Date) {
        if faviconCache[host] == nil { faviconCacheOrder.append(host) }
        faviconCache[host] = Timed(
            value: favicon,
            expiresAt: now.addingTimeInterval(Constants.Metadata.faviconCacheSeconds)
        )
        while faviconCacheOrder.count > Constants.Metadata.cacheEntryLimit {
            faviconCache[faviconCacheOrder.removeFirst()] = nil
        }
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
        return try Self.decodeMetadata(response.body, requestedURL: url)
    }

    static func decodeMetadata(_ data: Data, requestedURL: String) throws -> LinkMetadata {
        guard let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data),
               let responseURL = try? canonicalURL(decoded.url),
              responseURL == requestedURL else {
            throw LinkMetadataError.invalidPayload
        }
        return LinkMetadata(
            url: responseURL,
            title: normalizedText(decoded.title),
            description: normalizedText(decoded.description),
            siteName: normalizedText(decoded.siteName),
            image: normalizedRemoteImageURL(decoded.image),
            cached: decoded.cached ?? false
        )
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedRemoteImageURL(_ value: String?) -> String? {
        guard let value = normalizedText(value),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url.absoluteString
    }

    private func fetchFavicon(url: String) async throws -> Data {
        let client = try await getClient()
        let body = try JSONEncoder().encode(MetadataRequest(url: url))
        let response = try await client.post(
            url: "\(Constants.Metadata.enclaveURL)/favicon",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        guard (200..<300).contains(response.statusCode) else {
            throw LinkMetadataError.badStatus(response.statusCode)
        }
        return try Self.decodeFavicon(response.body)
    }

    static func decodeFavicon(_ data: Data) throws -> Data {
        guard let decoded = try? JSONDecoder().decode(FaviconResponse.self, from: data) else {
            throw LinkMetadataError.decodingFailed
        }
        if decoded.isMissing { throw LinkMetadataError.faviconMissing }
        guard decoded.found != false,
              decoded.missing != true,
              decoded.status != "missing",
              let bytes = decoded.faviconBytes,
              !bytes.isEmpty else {
            throw LinkMetadataError.invalidPayload
        }
        return bytes
    }

    private static func canonicalURL(_ value: String) throws -> String {
        guard var components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.port == nil || components.port == 80 || components.port == 443 else {
            throw LinkMetadataError.invalidURL
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        guard let canonical = components.string else { throw LinkMetadataError.invalidURL }
        return canonical
    }
}
