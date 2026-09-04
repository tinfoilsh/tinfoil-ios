//
//  GenUIConfigService.swift
//  TinfoilChat
//

import Foundation

struct GenUIRemoteConfig: Codable, Equatable {
    let header: String
    let enabledWidgets: [String]
}

enum GenUIConfigError: Error {
    case httpStatus(Int)
    case malformedPayload
}

@MainActor
final class GenUIConfigService {
    typealias DataLoader = (URL) async throws -> (Data, Int)

    static let shared = GenUIConfigService()

    private let dataLoader: DataLoader

    private(set) var config: GenUIRemoteConfig?

    init(dataLoader: @escaping DataLoader = GenUIConfigService.loadData) {
        self.dataLoader = dataLoader
    }

    /// Fetches the GenUI block from the controlplane. Failures propagate so
    /// the caller can treat GenUI config like any other required startup
    /// config; a previously loaded value is retained on failure.
    func refresh() async throws {
        let (data, statusCode) = try await dataLoader(Constants.Config.systemPromptURL)
        guard (200..<300).contains(statusCode) else {
            throw GenUIConfigError.httpStatus(statusCode)
        }
        guard let remoteConfig = Self.decodeConfig(from: data) else {
            throw GenUIConfigError.malformedPayload
        }
        config = remoteConfig
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
}
