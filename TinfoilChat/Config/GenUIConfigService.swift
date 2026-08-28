//
//  GenUIConfigService.swift
//  TinfoilChat
//

import Foundation

struct GenUIRemoteConfig: Codable, Equatable {
    let header: String
    let enabledWidgets: [String]
}

@MainActor
final class GenUIConfigService {
    typealias DataLoader = (URL) async throws -> (Data, Int)

    static let shared = GenUIConfigService()

    private struct CacheEntry: Codable {
        let cachedAt: Date
        let value: GenUIRemoteConfig
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let dataLoader: DataLoader

    private(set) var config: GenUIRemoteConfig?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        dataLoader: @escaping DataLoader = GenUIConfigService.loadData
    ) {
        self.defaults = defaults
        self.now = now
        self.dataLoader = dataLoader
        self.config = Self.readCachedConfig(defaults: defaults, now: now())
    }

    func refresh() async {
        do {
            let (data, statusCode) = try await dataLoader(Constants.Config.systemPromptURL)
            guard (200..<300).contains(statusCode) else { return }

            guard let remoteConfig = Self.decodeConfig(from: data) else {
                config = nil
                defaults.removeObject(forKey: Constants.Config.genUIConfigCacheKey)
                return
            }

            config = remoteConfig
            let entry = CacheEntry(cachedAt: now(), value: remoteConfig)
            if let encoded = try? JSONEncoder().encode(entry) {
                defaults.set(encoded, forKey: Constants.Config.genUIConfigCacheKey)
            }
        } catch {
            return
        }
    }

    static func loadData(from url: URL) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, statusCode)
    }

    private static func decodeConfig(from data: Data) -> GenUIRemoteConfig? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let root = decoded as? [String: Any],
              let rawConfig = root["genUI"] as? [String: Any],
              let header = rawConfig["header"] as? String,
              let rawWidgets = rawConfig["enabledWidgets"] as? [Any] else {
            return nil
        }

        return GenUIRemoteConfig(
            header: header,
            enabledWidgets: rawWidgets.compactMap { $0 as? String }
        )
    }

    private static func readCachedConfig(defaults: UserDefaults, now: Date) -> GenUIRemoteConfig? {
        guard let data = defaults.data(forKey: Constants.Config.genUIConfigCacheKey),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }

        let age = now.timeIntervalSince(entry.cachedAt)
        guard age >= 0, age <= Constants.Config.genUIConfigCacheMaxAge else {
            return nil
        }
        return entry.value
    }
}
