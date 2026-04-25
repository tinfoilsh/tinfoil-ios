//
//  GenUIStyle.swift
//  TinfoilChat
//
//  Shared SwiftUI styling primitives used across all GenUI widgets so the
//  rendered components feel like a coherent set.

import SwiftUI

enum GenUIStyle {
    static let cornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8
    static let chartHeight: CGFloat = 240

    static func borderColor(_ isDarkMode: Bool) -> Color {
        isDarkMode ? Color.white.opacity(0.15) : Color.black.opacity(0.12)
    }

    static func cardBackground(_ isDarkMode: Bool) -> Color {
        isDarkMode ? Color.white.opacity(0.04) : Color.black.opacity(0.025)
    }

    static func subtleBackground(_ isDarkMode: Bool) -> Color {
        isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    static func primaryText(_ isDarkMode: Bool) -> Color {
        isDarkMode ? Color.white : Color.black.opacity(0.9)
    }

    static func mutedText(_ isDarkMode: Bool) -> Color {
        isDarkMode ? Color.white.opacity(0.6) : Color.black.opacity(0.55)
    }

    /// Default categorical palette mirroring the webapp's pie-chart palette.
    static let palette: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.96), // blue
        Color(red: 0.06, green: 0.72, blue: 0.51), // green
        Color(red: 0.96, green: 0.62, blue: 0.04), // amber
        Color(red: 0.94, green: 0.27, blue: 0.27), // red
        Color(red: 0.55, green: 0.36, blue: 0.97), // violet
        Color(red: 0.93, green: 0.28, blue: 0.60), // pink
        Color(red: 0.02, green: 0.71, blue: 0.83), // cyan
        Color(red: 0.98, green: 0.45, blue: 0.09), // orange
    ]

    static func paletteColor(_ index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }

    /// Default accent (matches webapp's `#3b82f6`).
    static let accent: Color = Color(red: 0.23, green: 0.51, blue: 0.96)
}

/// Standard rounded card container used by most widgets.
struct GenUICardModifier: ViewModifier {
    let isDarkMode: Bool
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                    .fill(GenUIStyle.cardBackground(isDarkMode))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
            )
    }
}

extension View {
    func genUICard(isDarkMode: Bool, padding: CGFloat = 14) -> some View {
        modifier(GenUICardModifier(isDarkMode: isDarkMode, padding: padding))
    }
}

/// Optional title row with consistent typography across widgets.
struct GenUITitle: View {
    let text: String
    let isDarkMode: Bool

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(GenUIStyle.primaryText(isDarkMode))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders a remote image URL with a placeholder. Uses `AsyncImage` (iOS 15+).
struct GenUIRemoteImage: View {
    let url: String
    let isDarkMode: Bool
    var contentMode: ContentMode = .fill

    var body: some View {
        if let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https" {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(GenUIStyle.subtleBackground(isDarkMode))
                        .overlay(ProgressView().scaleEffect(0.7))
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                case .failure:
                    Rectangle()
                        .fill(GenUIStyle.subtleBackground(isDarkMode))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                        )
                @unknown default:
                    Rectangle().fill(GenUIStyle.subtleBackground(isDarkMode))
                }
            }
        } else {
            Rectangle()
                .fill(GenUIStyle.subtleBackground(isDarkMode))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                )
        }
    }
}

/// Opens a URL only when its scheme is http(s) — never `file://`, `javascript:`,
/// or other unsafe schemes the model could emit.
enum GenUIURLOpener {
    static func open(_ urlString: String) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto" else { return }
        UIApplication.shared.open(url)
    }
}
