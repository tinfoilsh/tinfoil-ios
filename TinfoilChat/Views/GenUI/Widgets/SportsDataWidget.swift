//
//  SportsDataWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

private let sportsLiveAccent = Color.red
private let sportsLiveBackgroundOpacity: Double = 0.12
private let sportsRowAltBackgroundOpacity: Double = 0.04
private let sportsLeaderHighlightOpacity: Double = 0.08

private func sportsIsLive(_ status: String?) -> Bool {
    guard let status, !status.isEmpty else { return false }
    let lowered = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.contains("live")
        || lowered.contains("in progress")
        || lowered.contains("halftime")
        || lowered.contains("half time")
        || lowered == "ot"
        || lowered.contains("overtime")
        || lowered.contains(" ot")
}

struct SportsDataWidget: GenUIWidget {
    struct Team: Decodable {
        let name: String
        let score: StringOrNumber?
        let logo: String?
        let rank: String?
    }

    struct Standing: Decodable {
        let team: String
        let wins: Double?
        let losses: Double?
        let ties: Double?
        let points: StringOrNumber?
        let gamesBack: String?
    }

    struct Args: Decodable {
        let sport: String?
        let kind: String
        let title: String?
        let status: String?
        let venue: String?
        let startTime: String?
        let home: Team?
        let away: Team?
        let standings: [Standing]?
    }

    let name = "render_sports_data"
    let description = "Display a sports fixture (game scoreline) or a league standings table. Use when the user asks about a game score, match result, or league table."
    let promptHint = "a sports fixture scoreline or a league standings table"

    var schema: JSONSchema {
        let team = GenUISchema.object(
            properties: [
                "name": GenUISchema.string(),
                "score": GenUISchema.stringOrNumber(),
                "logo": GenUISchema.string(),
                "rank": GenUISchema.string(),
            ],
            required: ["name"]
        )
        let standing = GenUISchema.object(
            properties: [
                "team": GenUISchema.string(),
                "wins": GenUISchema.number(),
                "losses": GenUISchema.number(),
                "ties": GenUISchema.number(),
                "points": GenUISchema.stringOrNumber(),
                "gamesBack": GenUISchema.string(),
            ],
            required: ["team"]
        )
        return GenUISchema.object(
            properties: [
                "sport": GenUISchema.string(description: "e.g. \"NBA\", \"Premier League\""),
                "kind": GenUISchema.string(
                    description: "`fixture` for a single game (scoreline), `standings` for a league table",
                    enumValues: ["fixture", "standings"]
                ),
                "title": GenUISchema.string(),
                "status": GenUISchema.string(description: "e.g. \"Final\", \"Live — 3rd quarter\", \"Scheduled\""),
                "venue": GenUISchema.string(),
                "startTime": GenUISchema.string(),
                "home": team,
                "away": team,
                "standings": GenUISchema.array(items: standing),
            ],
            required: ["kind"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(SportsDataView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct SportsDataView: View {
    let args: SportsDataWidget.Args
    let isDarkMode: Bool

    private var isLive: Bool { sportsIsLive(args.status) }

    private var leadingScore: Double? {
        guard let home = args.home?.score?.numericValue,
              let away = args.away?.score?.numericValue else { return nil }
        return max(home, away)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if args.kind == "fixture" {
                fixtureView
            } else if args.kind == "standings", let standings = args.standings, !standings.isEmpty {
                standingsView(standings: standings)
            }

            footer
        }
        .genUICard(isDarkMode: isDarkMode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sportsAccessibilityLabel)
    }

    private var sportsAccessibilityLabel: String {
        var parts: [String] = []
        if let sport = args.sport, !sport.isEmpty {
            parts.append(sport)
        }
        if let title = titleText {
            parts.append(title)
        }
        if args.kind == "fixture" {
            if let home = args.home, let away = args.away {
                if let homeScore = home.score?.stringValue, !homeScore.isEmpty,
                   let awayScore = away.score?.stringValue, !awayScore.isEmpty {
                    parts.append("\(home.name) \(homeScore), \(away.name) \(awayScore)")
                } else {
                    parts.append("\(home.name) vs \(away.name)")
                }
            }
            if let status = args.status, !status.isEmpty {
                parts.append(status)
            }
        } else if args.kind == "standings" {
            parts.append("Standings")
        }
        return parts.isEmpty ? "Sports data" : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let sport = args.sport, !sport.isEmpty {
                Text(sport.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            if let status = args.status, !status.isEmpty {
                statusPill(text: status)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusPill(text: String) -> some View {
        if isLive {
            HStack(spacing: 5) {
                Circle()
                    .fill(sportsLiveAccent)
                    .frame(width: 6, height: 6)
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(sportsLiveAccent)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(sportsLiveAccent.opacity(sportsLiveBackgroundOpacity))
            )
        } else {
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
        }
    }

    private var titleText: String? {
        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    @ViewBuilder
    private var footer: some View {
        if titleText != nil || venueText != nil || startTimeText != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let title = titleText {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
                if venueText != nil || startTimeText != nil {
                    HStack(spacing: 6) {
                        if let venue = venueText { Text(venue) }
                        if venueText != nil && startTimeText != nil { Text("\u{00B7}") }
                        if let startTime = startTimeText { Text(startTime) }
                    }
                    .font(.caption2)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
            }
        }
    }

    private var venueText: String? {
        guard let venue = args.venue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !venue.isEmpty else { return nil }
        return venue
    }

    private var startTimeText: String? {
        guard let startTime = args.startTime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !startTime.isEmpty else { return nil }
        return startTime
    }

    @ViewBuilder
    private var fixtureView: some View {
        HStack(alignment: .center, spacing: 16) {
            if let home = args.home {
                teamBlock(team: home, alignment: .leading)
            }
            if let home = args.home, let away = args.away {
                connector(home: home, away: away)
            } else {
                Text("VS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            if let away = args.away {
                teamBlock(team: away, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func connector(home: SportsDataWidget.Team, away: SportsDataWidget.Team) -> some View {
        if home.score?.numericValue == nil && away.score?.numericValue == nil,
           let startTime = args.startTime, !startTime.isEmpty {
            Text(startTime)
                .font(.caption2.weight(.semibold))
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
        } else {
            Text("–")
                .font(.system(size: 22, weight: .light, design: .rounded))
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
        }
    }

    private func teamBlock(team: SportsDataWidget.Team, alignment: HorizontalAlignment) -> some View {
        let isWinner = isWinningTeam(team)
        let isLoser = isLosingTeam(team)
        let scoreColor: Color = {
            if isLive { return .red }
            if isWinner { return GenUIStyle.accent }
            if isLoser { return GenUIStyle.mutedText(isDarkMode) }
            return GenUIStyle.primaryText(isDarkMode)
        }()
        let scoreWeight: Font.Weight = isWinner ? .bold : .semibold

        return VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 8) {
                if alignment == .trailing { Spacer(minLength: 0) }
                if let logo = team.logo, !logo.isEmpty {
                    GenUIRemoteImage(url: logo, isDarkMode: isDarkMode)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                }
                VStack(alignment: alignment, spacing: 1) {
                    Text(team.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .lineLimit(1)
                    if let rank = team.rank, !rank.isEmpty {
                        Text(rank)
                            .font(.caption2)
                            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                            .lineLimit(1)
                    }
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            Text(team.score?.stringValue ?? "—")
                .font(.system(size: 34, weight: scoreWeight, design: .rounded))
                .monospacedDigit()
                .foregroundColor(scoreColor)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func isWinningTeam(_ team: SportsDataWidget.Team) -> Bool {
        guard !isLive,
              let home = args.home?.score?.numericValue,
              let away = args.away?.score?.numericValue,
              home != away else { return false }
        if let value = team.score?.numericValue {
            return value == max(home, away)
        }
        return false
    }

    private func isLosingTeam(_ team: SportsDataWidget.Team) -> Bool {
        guard !isLive,
              let home = args.home?.score?.numericValue,
              let away = args.away?.score?.numericValue,
              home != away else { return false }
        if let value = team.score?.numericValue {
            return value == min(home, away)
        }
        return false
    }

    @ViewBuilder
    private func standingsView(standings: [SportsDataWidget.Standing]) -> some View {
        let hasGamesBack = standings.contains { ($0.gamesBack ?? "").isEmpty == false }

        VStack(spacing: 0) {
            ForEach(Array(standings.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider()
                        .background(GenUIStyle.borderColor(isDarkMode).opacity(0.6))
                }
                standingsRow(index: index, row: row, showGamesBack: hasGamesBack)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
                .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func standingsRow(
        index: Int,
        row: SportsDataWidget.Standing,
        showGamesBack: Bool
    ) -> some View {
        let isLeader = index == 0

        HStack(spacing: 12) {
            rankChip(index: index, isLeader: isLeader)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.team)
                    .font(.subheadline.weight(isLeader ? .semibold : .medium))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .lineLimit(1)
                Text(recordLabel(row))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showGamesBack, let gb = row.gamesBack, !gb.isEmpty {
                Text(gb)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }

            if let points = row.points?.stringValue, !points.isEmpty {
                Text(points)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(isLeader ? GenUIStyle.accent : GenUIStyle.primaryText(isDarkMode))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isLeader
                ? GenUIStyle.accent.opacity(0.10)
                : Color.clear
        )
    }

    @ViewBuilder
    private func rankChip(index: Int, isLeader: Bool) -> some View {
        Text("\(index + 1)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundColor(isLeader ? .white : GenUIStyle.mutedText(isDarkMode))
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(isLeader ? GenUIStyle.accent : GenUIStyle.primaryText(isDarkMode).opacity(sportsRowAltBackgroundOpacity * 2))
            )
    }

    private func recordLabel(_ row: SportsDataWidget.Standing) -> String {
        var parts: [String] = []
        if row.wins != nil { parts.append(numberLabel(row.wins)) }
        if row.losses != nil { parts.append(numberLabel(row.losses)) }
        if let ties = row.ties, ties > 0 { parts.append(numberLabel(ties)) }
        if parts.isEmpty { return "" }
        return parts.joined(separator: "–")
    }

    private func numberLabel(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(value)
    }
}

private extension StringOrNumber {
    var numericValue: Double? {
        Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
