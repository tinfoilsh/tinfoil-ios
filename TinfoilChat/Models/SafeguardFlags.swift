import Foundation

struct SafeguardFlag: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let conversationId: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case createdAt = "created_at"
    }

    var chatURL: URL? {
        guard !conversationId.isEmpty else { return nil }
        return Constants.Safeguards.chatBaseURL.appendingPathComponent(conversationId)
    }
}

struct SafeguardFlagsReport: Decodable, Equatable, Sendable {
    let flags: [SafeguardFlag]
    let inWindow: Int
    let windowHours: Int
    let warnThreshold: Int
    let banThreshold: Int

    enum CodingKeys: String, CodingKey {
        case flags
        case inWindow = "in_window"
        case windowHours = "window_hours"
        case warnThreshold = "warn_threshold"
        case banThreshold = "ban_threshold"
    }

    var flaggedChatIds: Set<String> {
        Set(flags.map(\.conversationId).filter { !$0.isEmpty })
    }

    var progress: Double {
        min(1, Double(inWindow) / Double(banThreshold))
    }

    var remaining: Int {
        max(0, banThreshold - inWindow)
    }

    var windowDescription: String {
        if windowHours.isMultiple(of: Constants.Safeguards.hoursPerDay) {
            let days = windowHours / Constants.Safeguards.hoursPerDay
            return days == 1 ? "1 day" : "\(days) days"
        }
        return windowHours == 1 ? "1 hour" : "\(windowHours) hours"
    }

    func isInWindow(_ flag: SafeguardFlag, now: Date) -> Bool {
        flag.createdAt >= now.addingTimeInterval(
            -Double(windowHours) * Constants.Safeguards.secondsPerHour
        )
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid flag timestamp")
            }
            return date
        }
        let report = try decoder.decode(Self.self, from: data)
        guard report.inWindow >= 0,
              report.windowHours > 0,
              report.warnThreshold >= 0,
              report.banThreshold > 0 else {
            throw SafeguardsError.invalidResponse
        }
        return Self(
            flags: report.flags.sorted { $0.createdAt > $1.createdAt },
            inWindow: report.inWindow,
            windowHours: report.windowHours,
            warnThreshold: report.warnThreshold,
            banThreshold: report.banThreshold
        )
    }

    #if DEBUG
    static func examples(now: Date) -> Self {
        let flags = Constants.Safeguards.exampleAgesInHours.enumerated().map { index, hours in
            let id = "\(Constants.Safeguards.exampleIDPrefix)\(index)"
            return SafeguardFlag(
                id: id,
                conversationId: id,
                createdAt: now.addingTimeInterval(-Double(hours) * Constants.Safeguards.secondsPerHour)
            )
        }
        return Self(
            flags: flags,
            inWindow: Constants.Safeguards.exampleAgesInHours.filter {
                $0 <= Constants.Safeguards.exampleWindowHours
            }.count,
            windowHours: Constants.Safeguards.exampleWindowHours,
            warnThreshold: Constants.Safeguards.exampleWarnThreshold,
            banThreshold: Constants.Safeguards.exampleBanThreshold
        )
    }
    #endif
}

enum SafeguardsError: Error {
    case authenticationRequired
    case invalidResponse
    case httpStatus(Int)
}
