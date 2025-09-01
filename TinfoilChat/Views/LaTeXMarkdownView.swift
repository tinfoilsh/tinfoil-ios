//
//  LaTeXMarkdownView.swift
//  TinfoilChat
//
//  Created on 09/01/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import MarkdownUI
import SwiftMath

/// A view that renders mixed Markdown and LaTeX content
struct LaTeXMarkdownView: View {
    let content: String
    let isDarkMode: Bool
    let horizontalPadding: CGFloat
    
    init(content: String, isDarkMode: Bool, horizontalPadding: CGFloat = 0) {
        self.content = content
        self.isDarkMode = isDarkMode
        self.horizontalPadding = horizontalPadding
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseContent(), id: \.id) { segment in
                segment.view
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    /// Parse content into segments of markdown and LaTeX
    private func parseContent() -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var currentPosition = content.startIndex
        
        // Regular expressions for LaTeX patterns
        let displayPattern = try? NSRegularExpression(pattern: "\\$\\$(.+?)\\$\\$", options: [.dotMatchesLineSeparators])
        let inlinePattern = try? NSRegularExpression(pattern: "(?<!\\$)\\$(?!\\$)(.+?)(?<!\\$)\\$(?!\\$)", options: [])
        
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        
        // Find all LaTeX expressions
        var latexRanges: [(range: NSRange, isDisplay: Bool)] = []
        
        // Find display math first ($$...$$)
        if let displayPattern = displayPattern {
            let displayMatches = displayPattern.matches(in: content, options: [], range: fullRange)
            for match in displayMatches {
                latexRanges.append((range: match.range, isDisplay: true))
            }
        }
        
        // Find inline math ($...$)
        if let inlinePattern = inlinePattern {
            let inlineMatches = inlinePattern.matches(in: content, options: [], range: fullRange)
            for match in inlineMatches {
                // Skip if this range overlaps with a display math range
                let overlaps = latexRanges.contains { displayRange in
                    NSLocationInRange(match.range.location, displayRange.range) ||
                    NSLocationInRange(displayRange.range.location, match.range)
                }
                if !overlaps {
                    latexRanges.append((range: match.range, isDisplay: false))
                }
            }
        }
        
        // Sort ranges by location
        latexRanges.sort { $0.range.location < $1.range.location }
        
        // Build segments
        for (range, isDisplay) in latexRanges {
            // Add markdown segment before this LaTeX expression
            if let swiftRange = Range(NSRange(location: NSLocationInRange(currentPosition.utf16Offset(in: content), fullRange) ? currentPosition.utf16Offset(in: content) : 0,
                                               length: range.location - (currentPosition.utf16Offset(in: content))),
                                       in: content),
               swiftRange.lowerBound < swiftRange.upperBound {
                let markdownText = String(content[swiftRange])
                if !markdownText.isEmpty {
                    segments.append(ContentSegment(
                        id: UUID().uuidString,
                        view: AnyView(
                            Markdown(markdownText)
                                .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                                .environment(\.colorScheme, isDarkMode ? .dark : .light)
                                .textSelection(.enabled)
                        )
                    ))
                }
            }
            
            // Add LaTeX segment
            if let swiftRange = Range(range, in: content) {
                let fullMatch = String(content[swiftRange])
                let latex: String
                
                if isDisplay {
                    // Remove $$ from both ends
                    latex = String(fullMatch.dropFirst(2).dropLast(2))
                } else {
                    // Remove $ from both ends
                    latex = String(fullMatch.dropFirst(1).dropLast(1))
                }
                
                segments.append(ContentSegment(
                    id: UUID().uuidString,
                    view: AnyView(
                        LaTeXView(
                            latex: latex,
                            isDisplay: isDisplay,
                            isDarkMode: isDarkMode
                        )
                    )
                ))
                
                // Update current position
                currentPosition = swiftRange.upperBound
            }
        }
        
        // Add remaining markdown after last LaTeX expression
        if currentPosition < content.endIndex {
            let remainingText = String(content[currentPosition...])
            if !remainingText.isEmpty {
                segments.append(ContentSegment(
                    id: UUID().uuidString,
                    view: AnyView(
                        Markdown(remainingText)
                            .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                            .environment(\.colorScheme, isDarkMode ? .dark : .light)
                            .textSelection(.enabled)
                    )
                ))
            }
        }
        
        // If no LaTeX was found, just render as pure markdown
        if segments.isEmpty {
            segments.append(ContentSegment(
                id: UUID().uuidString,
                view: AnyView(
                    Markdown(content)
                        .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                        .environment(\.colorScheme, isDarkMode ? .dark : .light)
                        .textSelection(.enabled)
                )
            ))
        }
        
        return segments
    }
    
    private struct ContentSegment {
        let id: String
        let view: AnyView
    }
}

/// A view that renders LaTeX equations using SwiftMath
struct LaTeXView: View {
    let latex: String
    let isDisplay: Bool
    let isDarkMode: Bool
    
    var body: some View {
        MathView(
            latex: latex,
            displayMode: isDisplay,
            isDarkMode: isDarkMode
        )
        .frame(maxWidth: .infinity, alignment: isDisplay ? .center : .leading)
        .padding(.vertical, isDisplay ? 8 : 2)
    }
}

/// Bridge to SwiftMath's MTMathUILabel
struct MathView: UIViewRepresentable {
    let latex: String
    let displayMode: Bool
    let isDarkMode: Bool
    
    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.latex = latex
        label.labelMode = displayMode ? .display : .text
        label.textColor = isDarkMode ? .white : .black.withAlphaComponent(0.8)
        label.fontSize = displayMode ? 18 : 16
        label.textAlignment = displayMode ? .center : .left
        label.backgroundColor = .clear
        label.isUserInteractionEnabled = true
        return label
    }
    
    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        uiView.latex = latex
        uiView.labelMode = displayMode ? .display : .text
        uiView.textColor = isDarkMode ? .white : .black.withAlphaComponent(0.8)
        uiView.fontSize = displayMode ? 18 : 16
        uiView.textAlignment = displayMode ? .center : .left
    }
}

/// Cached markdown themes (referenced from original MessageView)
private struct MarkdownThemeCache {
    static let darkTheme = createTheme(isDarkMode: true)
    static let lightTheme = createTheme(isDarkMode: false)
    
    static func getTheme(isDarkMode: Bool) -> MarkdownUI.Theme {
        isDarkMode ? darkTheme : lightTheme
    }
    
    private static func createTheme(isDarkMode: Bool) -> MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                FontFamily(.system(.default))
                FontSize(.em(1.0))
                ForegroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            }
            .codeBlock { configuration in
                configuration.label
                    .padding()
                    .background(isDarkMode ? Color.black.opacity(0.2) : Color.gray.opacity(0.05))
                    .cornerRadius(8)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 20, bottom: 10)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.75))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 16, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.5))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 14, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.25))
                    }
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontStyle(.italic)
                        ForegroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .markdownMargin(top: 8, bottom: 8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.2)))
                }
            }
    }
}