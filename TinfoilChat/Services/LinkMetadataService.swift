//
//  LinkMetadataService.swift
//  TinfoilChat
//
//  A page's link preview and a site's favicon, which the chat service reads
//  inside its enclave so citation chips and link cards never reach an
//  external host directly. In-flight requests for the same URL are shared,
//  so multiple cards rendering the same link make one round-trip.
//

import Foundation

enum LinkMetadataError: LocalizedError {
    case invalidURL
    case unavailable
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The link is not a valid web address."
        case .unavailable: return "Link previews are not available right now."
        case .notFound: return "The site has no icon."
        }
    }
}

actor LinkMetadataService {
    static let shared = LinkMetadataService()

    private var cache: [String: LinkPreview] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LinkPreview, Error>] = [:]
    private var faviconCache: [String: Data] = [:]
    private var faviconCacheOrder: [String] = []
    private var faviconInFlight: [String: Task<Data, Error>] = [:]
    private let images = NSCache<NSString, NSData>()
    private var imageInFlight: [String: Task<Data, Error>] = [:]
    private weak var account: HarnessAccount?

    init() {
        images.countLimit = Constants.Metadata.imageCacheEntryLimit
        images.totalCostLimit = Constants.Metadata.imageCacheBytes
    }

    /// The account whose session reads previews, which changes as the
    /// account does. Previews in flight for the account before are not
    /// waited on: a card asks again through the new one.
    func bind(_ account: HarnessAccount?) {
        imageInFlight.values.forEach { $0.cancel() }
        imageInFlight = [:]
        images.removeAllObjects()
        self.account = account
        inFlight = [:]
        faviconInFlight = [:]
    }

    func metadata(for url: String) async throws -> LinkPreview {
        if let cached = cache[url] { return cached }
        if let existing = inFlight[url] { return try await existing.value }
        guard let account else { throw LinkMetadataError.unavailable }
        let task = Task<LinkPreview, Error> {
            try await HarnessMetadata.link(account, url: url)
        }
        inFlight[url] = task
        defer { if inFlight[url] == task { inFlight[url] = nil } }
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
        guard let account else { throw LinkMetadataError.unavailable }
        let task = Task<Data, Error> {
            guard let favicon = try await HarnessMetadata.favicon(account, url: url) else { throw LinkMetadataError.notFound }
            return favicon.data
        }
        faviconInFlight[host] = task
        defer { if faviconInFlight[host] == task { faviconInFlight[host] = nil } }
        let result = try await task.value
        storeFaviconInCache(result, for: host)
        return result
    }

    func image(for rawURL: String) async throws -> Data {
        guard rawURL.utf8.count <= Constants.Metadata.imageURLLengthLimit,
              let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil else {
            throw LinkMetadataError.invalidURL
        }
        guard let account else { throw LinkMetadataError.unavailable }
        let key = url.absoluteString
        if let cached = images.object(forKey: key as NSString) { return cached as Data }
        let task: Task<Data, Error>
        if let existing = imageInFlight[key] {
            task = existing
        } else {
            task = Task<Data, Error> {
                try await HarnessMetadata.image(account, url: key)
            }
            imageInFlight[key] = task
        }
        defer { if imageInFlight[key] == task { imageInFlight[key] = nil } }
        let data = try await task.value
        guard self.account === account else { throw CancellationError() }
        images.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        try Task.checkCancellation()
        return data
    }

    private func storeInCache(_ metadata: LinkPreview, for url: String) {
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
}
