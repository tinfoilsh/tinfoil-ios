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
import UIKit
import Splash

private struct ContentSegment {
    let id: String
    let view: AnyView
}

/// Global cache for rendered markdown content
private class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private var cache: [String: [ContentSegment]] = [:]
    private let queue = DispatchQueue(label: "com.tinfoil.markdown-cache", attributes: .concurrent)

    func get(for key: String) -> [ContentSegment]? {
        queue.sync {
            cache[key]
        }
    }

    func set(_ segments: [ContentSegment], for key: String) {
        queue.async(flags: .barrier) {
            self.cache[key] = segments
        }
    }

    func clear() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}

/// A view that renders mixed Markdown and LaTeX content
struct LaTeXMarkdownView: View, Equatable {
    let content: String
    let isDarkMode: Bool
    let horizontalPadding: CGFloat
    let maxWidthAlignment: Alignment
    let isStreaming: Bool

    static func == (lhs: LaTeXMarkdownView, rhs: LaTeXMarkdownView) -> Bool {
        lhs.content == rhs.content &&
        lhs.isDarkMode == rhs.isDarkMode &&
        lhs.horizontalPadding == rhs.horizontalPadding &&
        lhs.maxWidthAlignment == rhs.maxWidthAlignment &&
        lhs.isStreaming == rhs.isStreaming
    }

    init(content: String, isDarkMode: Bool, horizontalPadding: CGFloat = 0, maxWidthAlignment: Alignment = .leading, isStreaming: Bool = false) {
        self.content = content
        self.isDarkMode = isDarkMode
        self.horizontalPadding = horizontalPadding
        self.maxWidthAlignment = maxWidthAlignment
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(getOrCreateSegments(), id: \.id) { segment in
                segment.view
                    .id(segment.id)
            }
        }
        .environment(\.colorScheme, isDarkMode ? .dark : .light)
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: horizontalPadding > 0 ? .infinity : nil, alignment: maxWidthAlignment)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func getOrCreateSegments() -> [ContentSegment] {
        if isStreaming {
            return [ContentSegment(
                id: "streaming_\(content.hashValue)",
                view: AnyView(
                    Markdown(content)
                        .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                        .markdownCodeSyntaxHighlighter(.splash(theme: MarkdownThemeCache.getSplashTheme(isDarkMode: isDarkMode)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                )
            )]
        }

        let cacheKey = "\(content)_\(isDarkMode)"

        if let cached = MarkdownRenderCache.shared.get(for: cacheKey) {
            return cached
        }

        let segments = parseContent()
        MarkdownRenderCache.shared.set(segments, for: cacheKey)
        return segments
    }
    
    /// Parse content into segments of markdown and LaTeX
    private func parseContent() -> [ContentSegment] {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        var excludedRanges: [NSRange] = []

        if let codeBlockRegex = try? NSRegularExpression(pattern: "```[\\s\\S]*?```", options: []) {
            let matches = codeBlockRegex.matches(in: content, options: [], range: fullRange)
            excludedRanges.append(contentsOf: matches.map(\.range))
        }

        if let inlineCodeRegex = try? NSRegularExpression(pattern: "`[^`]+`", options: []) {
            let matches = inlineCodeRegex.matches(in: content, options: [], range: fullRange)
            for match in matches where !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                excludedRanges.append(match.range)
            }
        }

        let tableSegments = findMarkdownTables(in: content)
        excludedRanges.append(contentsOf: tableSegments.map(\.range))

        func isExcluded(_ range: NSRange) -> Bool {
            excludedRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        var latexRanges: [(range: NSRange, isDisplay: Bool)] = []

        if let displayRegex = try? NSRegularExpression(pattern: "\\\\\\[(.+?)\\\\\\]", options: [.dotMatchesLineSeparators]) {
            let matches = displayRegex.matches(in: content, options: [], range: fullRange)
            for match in matches where !isExcluded(match.range) {
                latexRanges.append((match.range, true))
            }
        }

        if let inlineRegex = try? NSRegularExpression(pattern: "\\\\\\((.+?)\\\\\\)", options: []) {
            let matches = inlineRegex.matches(in: content, options: [], range: fullRange)
            for match in matches where !isExcluded(match.range) {
                let overlaps = latexRanges.contains { existing in
                    NSLocationInRange(match.range.location, existing.range) ||
                    NSLocationInRange(existing.range.location, match.range)
                }
                if !overlaps {
                    latexRanges.append((match.range, false))
                }
            }
        }

        latexRanges.sort { $0.range.location < $1.range.location }

        var specialSegments: [SpecialSegment] = latexRanges.map { match in
            SpecialSegment(range: match.range, kind: .latex(isDisplay: match.isDisplay))
        }
        specialSegments.append(contentsOf: tableSegments.map { table in
            SpecialSegment(range: table.range, kind: .table(table.table))
        })
        specialSegments.sort { $0.range.location < $1.range.location }

        var segments: [ContentSegment] = []
        var lastIndex = content.startIndex

        for special in specialSegments {
            guard let swiftRange = Range(special.range, in: content) else { continue }

            if lastIndex < swiftRange.lowerBound {
                let markdownText = String(content[lastIndex..<swiftRange.lowerBound])
                if !markdownText.isEmpty {
                    segments.append(ContentSegment(
                        id: "md_\(special.range.location)_\(markdownText.hashValue)",
                        view: AnyView(
                            Markdown(markdownText)
                                .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                                .markdownCodeSyntaxHighlighter(.splash(theme: MarkdownThemeCache.getSplashTheme(isDarkMode: isDarkMode)))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        )
                    ))
                }
            }

            switch special.kind {
            case let .latex(isDisplay):
                let fullMatch = String(content[swiftRange])
                let latex: String

                if isDisplay {
                    if fullMatch.hasPrefix("\\[") && fullMatch.hasSuffix("\\]") {
                        latex = String(fullMatch.dropFirst(2).dropLast(2))
                    } else {
                        latex = fullMatch
                    }
                } else {
                    if fullMatch.hasPrefix("\\(") && fullMatch.hasSuffix("\\)") {
                        latex = String(fullMatch.dropFirst(2).dropLast(2))
                    } else {
                        latex = fullMatch
                    }
                }

                let sanitizedLatex = sanitizeLatex(latex)

                segments.append(ContentSegment(
                    id: "latex_\(special.range.location)_\(sanitizedLatex.hashValue)",
                    view: AnyView(
                        LaTeXView(
                            latex: sanitizedLatex,
                            isDisplay: isDisplay,
                            isDarkMode: isDarkMode
                        )
                    )
                ))
            case let .table(table):
                segments.append(ContentSegment(
                    id: "table_\(special.range.location)",
                    view: AnyView(
                        MarkdownTableView(
                            table: table,
                            isDarkMode: isDarkMode
                        )
                    )
                ))
            }

            lastIndex = swiftRange.upperBound
        }

        if lastIndex < content.endIndex {
            let remainingText = String(content[lastIndex...])
            if !remainingText.isEmpty {
                segments.append(ContentSegment(
                    id: "md_end_\(remainingText.hashValue)",
                    view: AnyView(
                        Markdown(remainingText)
                            .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                            .markdownCodeSyntaxHighlighter(.splash(theme: MarkdownThemeCache.getSplashTheme(isDarkMode: isDarkMode)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    )
                ))
            }
        }

        if segments.isEmpty {
            segments.append(ContentSegment(
                id: "md_full_\(content.hashValue)",
                view: AnyView(
                    Markdown(content)
                        .markdownTheme(MarkdownThemeCache.getTheme(isDarkMode: isDarkMode))
                        .markdownCodeSyntaxHighlighter(.splash(theme: MarkdownThemeCache.getSplashTheme(isDarkMode: isDarkMode)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                )
            ))
        }

        return segments
    }

    private func sanitizeLatex(_ latex: String) -> String {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? latex : trimmed

        guard base.contains("\\text{") else { return base }

        return normalizeTextCommands(in: base)
    }

    private func normalizeTextCommands(in latex: String) -> String {
        var result = ""
        var index = latex.startIndex

        while index < latex.endIndex {
            if latex[index...].hasPrefix("\\text{") {
                let contentStart = latex.index(index, offsetBy: 6)
                var cursor = contentStart
                var depth = 1

                while cursor < latex.endIndex && depth > 0 {
                    let character = latex[cursor]
                    if character == "{" {
                        depth += 1
                    } else if character == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    cursor = latex.index(after: cursor)
                }

                if depth == 0 {
                    let content = String(latex[contentStart..<cursor])
                    result += rewriteTextContent(content)
                    index = latex.index(after: cursor)
                } else {
                    result += String(latex[index...])
                    break
                }
            } else {
                result.append(latex[index])
                index = latex.index(after: index)
            }
        }

        return result
    }

    private func rewriteTextContent(_ content: String) -> String {
        guard content.contains("\\(") else {
            return "\\text{\(content)}"
        }

        var result = ""
        var currentIndex = content.startIndex

        while let openRange = content.range(of: "\\(", range: currentIndex..<content.endIndex) {
            let textSegment = String(content[currentIndex..<openRange.lowerBound])
            if !textSegment.isEmpty {
                result += "\\text{\(textSegment)}"
            }

            let mathStart = openRange.upperBound
            guard let closeRange = content.range(of: "\\)", range: mathStart..<content.endIndex) else {
                let remainder = String(content[openRange.lowerBound..<content.endIndex])
                if !remainder.isEmpty {
                    result += "\\text{\(remainder)}"
                }
                return result
            }

            let mathContent = String(content[mathStart..<closeRange.lowerBound])
            result += mathContent
            currentIndex = closeRange.upperBound
        }

        let trailingText = String(content[currentIndex..<content.endIndex])
        if !trailingText.isEmpty {
            result += "\\text{\(trailingText)}"
        }

        return result
    }

    private struct SpecialSegment {
        let range: NSRange
        let kind: Kind

        enum Kind {
            case latex(isDisplay: Bool)
            case table(ParsedTable)
        }
    }

    private struct TableMatch {
        let range: NSRange
        let table: ParsedTable
    }

    private struct LineInfo {
        let text: String
        let enclosingRange: Range<String.Index>
    }

    private func findMarkdownTables(in content: String) -> [TableMatch] {
        guard content.contains("|") else { return [] }

        var lines: [LineInfo] = []
        content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: .byLines) { substring, _, enclosingRange, _ in
            let line = substring ?? ""
            lines.append(LineInfo(text: line, enclosingRange: enclosingRange))
        }

        var matches: [TableMatch] = []
        var index = 0

        while index < lines.count {
            let headerLine = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard headerLine.hasPrefix("|") && headerLine.contains("|") else {
                index += 1
                continue
            }

            let alignmentIndex = index + 1
            guard alignmentIndex < lines.count else {
                index += 1
                continue
            }

            let alignmentLine = lines[alignmentIndex].text
            guard isAlignmentLine(alignmentLine) else {
                index += 1
                continue
            }

            var collected = [lines[index].text, alignmentLine]
            var lastIndex = alignmentIndex
            var rowIndex = alignmentIndex + 1

            while rowIndex < lines.count {
                let candidate = lines[rowIndex].text.trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty { break }
                guard candidate.hasPrefix("|") && candidate.contains("|") else { break }
                collected.append(lines[rowIndex].text)
                lastIndex = rowIndex
                rowIndex += 1
            }

            if let parsed = parseTable(lines: collected) {
                let lowerBound = lines[index].enclosingRange.lowerBound
                let upperBound = lines[lastIndex].enclosingRange.upperBound
                let range = NSRange(lowerBound..<upperBound, in: content)
                matches.append(TableMatch(range: range, table: parsed))
                index = lastIndex + 1
            } else {
                index += 1
            }
        }

        return matches
    }

    private func parseTable(lines: [String]) -> ParsedTable? {
        guard lines.count >= 2 else { return nil }

        let headerCells = parseTableCells(from: lines[0])
        let alignmentCells = parseAlignmentRow(from: lines[1], columnCount: headerCells.count)
        guard !headerCells.isEmpty else { return nil }

        let columnCount = max(headerCells.count, alignmentCells.count)
        let normalizedHeader = normalizeRow(headerCells, targetCount: columnCount)
        let normalizedAlignments = alignmentCells.count == columnCount ? alignmentCells : normalizeAlignments(alignmentCells, targetCount: columnCount)

        var rows: [[String]] = []
        for line in lines.dropFirst(2) {
            let cells = parseTableCells(from: line)
            rows.append(normalizeRow(cells, targetCount: columnCount))
        }

        return ParsedTable(headers: normalizedHeader, alignments: normalizedAlignments, rows: rows)
    }

    private func parseAlignmentRow(from line: String, columnCount: Int) -> [TableAlignment] {
        let cells = parseTableCells(from: line)
        guard !cells.isEmpty else { return Array(repeating: .leading, count: columnCount) }

        let alignments = cells.map { cell -> TableAlignment in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")

            switch (leading, trailing) {
            case (true, true):
                return .center
            case (false, true):
                return .trailing
            default:
                return .leading
            }
        }

        return normalizeAlignments(alignments, targetCount: max(columnCount, alignments.count))
    }

    private func normalizeAlignments(_ alignments: [TableAlignment], targetCount: Int) -> [TableAlignment] {
        if alignments.count == targetCount {
            return alignments
        } else if alignments.count < targetCount {
            return alignments + Array(repeating: .leading, count: targetCount - alignments.count)
        } else {
            return Array(alignments.prefix(targetCount))
        }
    }

    private func normalizeRow(_ cells: [String], targetCount: Int) -> [String] {
        if cells.count == targetCount {
            return cells
        } else if cells.count < targetCount {
            return cells + Array(repeating: "", count: targetCount - cells.count)
        } else {
            return Array(cells.prefix(targetCount))
        }
    }

    private func parseTableCells(from line: String) -> [String] {
        let placeholder = "__ESCAPED_PIPE__"
        var working = line.trimmingCharacters(in: .whitespaces)

        while working.hasPrefix("|") {
            working.removeFirst()
        }
        while working.hasSuffix("|") {
            working.removeLast()
        }

        working = working.replacingOccurrences(of: "\\|", with: placeholder)

        let parts = working.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return parts.map { part in
            part.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    private func isAlignmentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }

        let cells = parseTableCells(from: line)
        guard !cells.isEmpty else { return false }

        let allowed = CharacterSet(charactersIn: "-: ")
        return cells.allSatisfy { cell in
            let cellTrimmed = cell.trimmingCharacters(in: .whitespaces)
            guard cellTrimmed.contains("-") else { return false }
            return cellTrimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

private struct ParsedTable {
    let headers: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]
}

private enum TableAlignment {
    case leading
    case center
    case trailing

    var viewAlignment: Alignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
}

private struct MarkdownTableView: View {
    let table: ParsedTable
    let isDarkMode: Bool

    @State private var columnWidths: [Int: CGFloat] = [:]

    private var borderColor: SwiftUI.Color {
        isDarkMode ? SwiftUI.Color.white.opacity(0.2) : SwiftUI.Color.black.opacity(0.2)
    }

    private var headerBackground: SwiftUI.Color {
        SwiftUI.Color.clear
    }

    private var alternatingRowBackground: SwiftUI.Color {
        SwiftUI.Color.clear
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tableContainer(useColumnWidths: true)
            ScrollView(.horizontal, showsIndicators: true) {
                tableContainer(useColumnWidths: true)
            }
        }
        .padding(.vertical, 8)
        .background(
            tableContainer(useColumnWidths: false)
                .hidden()
                .onPreferenceChange(ColumnWidthPreferenceKey.self) { newValues in
                    let cappedValues = newValues.mapValues { min($0, Constants.UI.tableMaxColumnWidth) }
                    if columnWidths != cappedValues {
                        columnWidths = cappedValues
                    }
                }
        )
    }

    private func tableContainer(useColumnWidths: Bool) -> some View {
        VStack(spacing: 0) {
            if !table.headers.isEmpty {
                MarkdownTableRowView(
                    cells: table.headers,
                    alignments: table.alignments,
                    isHeader: true,
                    isDarkMode: isDarkMode,
                    borderColor: borderColor,
                    background: headerBackground,
                    columnWidths: useColumnWidths ? columnWidths : [:],
                    measureColumns: !useColumnWidths
                )
                Rectangle()
                    .fill(borderColor)
                    .frame(height: 1)
            }

            ForEach(table.rows.indices, id: \.self) { index in
                MarkdownTableRowView(
                    cells: table.rows[index],
                    alignments: table.alignments,
                    isHeader: false,
                    isDarkMode: isDarkMode,
                    borderColor: borderColor,
                    background: index.isMultiple(of: 2) ? alternatingRowBackground : SwiftUI.Color.clear,
                    columnWidths: useColumnWidths ? columnWidths : [:],
                    measureColumns: !useColumnWidths
                )

                if index < table.rows.count - 1 {
                    Rectangle()
                        .fill(borderColor)
                        .frame(height: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

private struct MarkdownTableRowView: View {
    let cells: [String]
    let alignments: [TableAlignment]
    let isHeader: Bool
    let isDarkMode: Bool
    let borderColor: SwiftUI.Color
    let background: SwiftUI.Color
    let columnWidths: [Int: CGFloat]
    let measureColumns: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                MarkdownTableCell(
                    content: cells[index],
                    alignment: alignments.indices.contains(index) ? alignments[index] : .leading,
                    isHeader: isHeader,
                    isDarkMode: isDarkMode,
                    columnIndex: index,
                    columnWidth: columnWidths[index],
                    measureColumn: measureColumns,
                    background: background
                )
                .frame(maxHeight: .infinity, alignment: .top)

                if index < cells.count - 1 {
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: 1)
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownTableCell: View {
    let content: String
    let alignment: TableAlignment
    let isHeader: Bool
    let isDarkMode: Bool
    let columnIndex: Int
    let columnWidth: CGFloat?
    let measureColumn: Bool
    let background: SwiftUI.Color

    var body: some View {
        let cellContent = LaTeXMarkdownView(
            content: content.isEmpty ? " " : content,
            isDarkMode: isDarkMode,
            horizontalPadding: 0,
            maxWidthAlignment: alignment.viewAlignment
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, isHeader ? 6 : 5)
        .padding(.horizontal, 12)

        if measureColumn {
            cellContent
                .fixedSize(horizontal: true, vertical: true)
                .background(ColumnWidthReader(columnIndex: columnIndex))
        } else if let width = columnWidth {
            cellContent
                .frame(width: width, alignment: alignment.viewAlignment)
                .frame(maxHeight: .infinity)
                .background(background)
        } else {
            cellContent
                .frame(maxHeight: .infinity)
                .background(background)
        }
    }
}

private struct ColumnWidthReader: View {
    let columnIndex: Int

    var body: some View {
        GeometryReader { proxy in
            SwiftUI.Color.clear
                .preference(key: ColumnWidthPreferenceKey.self, value: [columnIndex: proxy.size.width])
        }
    }
}

private struct ColumnWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        let newValue = nextValue()
        for (index, width) in newValue {
            if let existing = value[index] {
                value[index] = max(existing, width)
            } else {
                value[index] = width
            }
        }
    }
}

/// A view that renders LaTeX equations using SwiftMath
struct LaTeXView: View {
    let latex: String
    let isDisplay: Bool
    let isDarkMode: Bool
    
    var body: some View {
        if isDisplay {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MathView(
                        latex: latex,
                        displayMode: true,
                        isDarkMode: isDarkMode
                    )
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            MathView(
                latex: latex,
                displayMode: false,
                isDarkMode: isDarkMode
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
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
        label.contentInsets = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.sizeToFit()
        return label
    }
    
    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        uiView.latex = latex
        uiView.labelMode = displayMode ? .display : .text
        uiView.textColor = isDarkMode ? .white : .black.withAlphaComponent(0.8)
        uiView.fontSize = displayMode ? 18 : 16
        uiView.textAlignment = displayMode ? .center : .left
        uiView.contentInsets = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        uiView.setContentCompressionResistancePriority(.required, for: .vertical)
        uiView.setContentHuggingPriority(.required, for: .vertical)
        uiView.sizeToFit()
    }
}

/// Cached markdown themes (referenced from original MessageView)
private struct MarkdownThemeCache {
    static let darkTheme = createTheme(isDarkMode: true)
    static let lightTheme = createTheme(isDarkMode: false)

    static func getTheme(isDarkMode: Bool) -> MarkdownUI.Theme {
        isDarkMode ? darkTheme : lightTheme
    }

    static func getSplashTheme(isDarkMode: Bool) -> Splash.Theme {
        isDarkMode ? .wwdc17(withFont: .init(size: 16)) : .sunset(withFont: .init(size: 16))
    }

    private static func createTheme(isDarkMode: Bool) -> MarkdownUI.Theme {

        let baseTheme = MarkdownUI.Theme.gitHub
            .text {
                FontFamily(.system(.default))
                FontSize(15)
                ForegroundColor(isDarkMode ? .white : Color.black.opacity(0.8))
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 12)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            }
            .codeBlock { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding()
                    .background(isDarkMode ? SwiftUI.Color.black.opacity(0.2) : SwiftUI.Color.gray.opacity(0.05))
                    .cornerRadius(8)
            }

        let withHeadings = baseTheme
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

        let withBlockElements = withHeadings
            .blockquote { configuration in
                let paddedLabel = configuration.label
                    .markdownTextStyle {
                        FontStyle(.italic)
                        ForegroundColor(.secondary)
                    }
                    .markdownMargin(top: 8, bottom: 8)

                return paddedLabel
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(SwiftUI.Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }

        return withBlockElements
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTableBorderStyle(MarkdownUI.TableBorderStyle(color: isDarkMode ? SwiftUI.Color.white.opacity(0.2) : SwiftUI.Color.black.opacity(0.2)))
                }
            }
    }
}
