//
//  SportsDataWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct SportsDataWidget: GenUIWidget {
    struct Team: Decodable {
        let name: String
        let score: StringOrNumber?
        let logo: String?
        let rank: String?
    }

    struct Standing: Decodable {
        let team: String
        let wins: Int?
        let losses: Int?
        let ties: Int?
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
    let description = "Display a sports fixture (game scoreline) or a league standings table."
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
                "wins": GenUISchema.integer(),
                "losses": GenUISchema.integer(),
                "ties": GenUISchema.integer(),
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
                "status": GenUISchema.string(),
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let sport = args.sport, !sport.isEmpty {
                    Text(sport.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                if args.sport != nil && args.status != nil { Text("\u{00B7}").foregroundColor(GenUIStyle.mutedText(isDarkMode)) }
                if let status = args.status, !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
            }

            if let title = args.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
            }

            if args.kind == "fixture" {
                fixtureView
            } else if args.kind == "standings", let standings = args.standings, !standings.isEmpty {
                standingsView(standings: standings)
            }

            if args.venue != nil || args.startTime != nil {
                HStack(spacing: 6) {
                    if let venue = args.venue, !venue.isEmpty { Text(venue) }
                    if args.venue != nil && args.startTime != nil { Text("\u{00B7}") }
                    if let startTime = args.startTime, !startTime.isEmpty { Text(startTime) }
                }
                .font(.caption2)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
        }
        .genUICard(isDarkMode: isDarkMode)
    }

    @ViewBuilder
    private var fixtureView: some View {
        HStack(alignment: .center, spacing: 12) {
            if let home = args.home {
                teamBlock(team: home, alignment: .leading)
            }
            Text("VS")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            if let away = args.away {
                teamBlock(team: away, alignment: .trailing)
            }
        }
    }

    private func teamBlock(team: SportsDataWidget.Team, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                if alignment == .trailing { Spacer(minLength: 0) }
                if let logo = team.logo, !logo.isEmpty {
                    GenUIRemoteImage(url: logo, isDarkMode: isDarkMode)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                }
                Text(team.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                if alignment == .leading { Spacer(minLength: 0) }
            }
            if let rank = team.rank, !rank.isEmpty {
                Text(rank)
                    .font(.caption2)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
            Text(team.score?.stringValue ?? "—")
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    @ViewBuilder
    private func standingsView(standings: [SportsDataWidget.Standing]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Team").frame(maxWidth: .infinity, alignment: .leading)
                Text("W").frame(width: 28, alignment: .trailing)
                Text("L").frame(width: 28, alignment: .trailing)
                Text("T").frame(width: 28, alignment: .trailing)
                Text("Pts").frame(width: 36, alignment: .trailing)
                Text("GB").frame(width: 32, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            .padding(.bottom, 6)
            .overlay(Rectangle().frame(height: 1).foregroundColor(GenUIStyle.borderColor(isDarkMode)), alignment: .bottom)

            ForEach(Array(standings.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.team)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    Text(row.wins.map(String.init) ?? "").frame(width: 28, alignment: .trailing)
                    Text(row.losses.map(String.init) ?? "").frame(width: 28, alignment: .trailing)
                    Text(row.ties.map(String.init) ?? "").frame(width: 28, alignment: .trailing)
                    Text(row.points?.stringValue ?? "").frame(width: 36, alignment: .trailing)
                    Text(row.gamesBack ?? "")
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        .frame(width: 32, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                .padding(.vertical, 6)
                .overlay(Rectangle().frame(height: 1).foregroundColor(GenUIStyle.borderColor(isDarkMode).opacity(0.5)), alignment: .bottom)
            }
        }
    }
}
