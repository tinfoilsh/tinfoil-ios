//
//  PasskeyDiagnostics.swift
//  TinfoilChat
//
//  Central diagnostics for the passkey unlock/setup flows. Every
//  decision point is recorded to OSLog and mirrored into Sentry
//  breadcrumbs so a user-reported "Passkey authentication failed"
//  carries the exact step that failed instead of one collapsed
//  error string.
//
//  Never logs key material, PRF outputs, or credential IDs. Key ids
//  are HKDF-derived public identifiers (the server stores them in
//  the clear); only a short prefix is logged to correlate devices.
//

import Foundation
import OSLog
import Sentry

enum PasskeyDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TinfoilChat",
        category: "Passkey"
    )

    /// Bound on underlying-error traversal in `describe`. Real error
    /// chains are 2-3 deep; the cap guards against pathological or
    /// cyclic userInfo chains.
    private static let maxErrorChainDepth = 5

    /// What a reported failure is. Sentry groups the reports by it: they
    /// all come from the same few lines, which is all it would otherwise
    /// have to tell them apart by.
    enum ReportKind {
        case settingsAlert
        case recoveredKeyInvalid
        case ceremony(PasskeyFlowFailure)

        fileprivate var fingerprint: [String] {
            switch self {
            case .settingsAlert: return [fingerprintPrefix, "settings-alert"]
            case .recoveredKeyInvalid: return [fingerprintPrefix, "recovered-key-invalid"]
            case .ceremony(let failure): return [fingerprintPrefix, "ceremony", failure.rawValue]
            }
        }
    }

    private static let fingerprintPrefix = "passkey"
    private static let breadcrumbCategory = "passkey"
    private static let breadcrumbDetailKey = "detail"

    /// Log a flow milestone (which path was taken, candidate counts).
    static func step(_ message: String) {
        logger.info("\(message, privacy: .public)")
        addBreadcrumb(message, level: .info)
    }

    /// Log a non-fatal anomaly worth seeing in a report. The detail is
    /// what a framework or a service said of it, as for `failure`.
    static func warn(_ message: String, detail: String? = nil) {
        logger.warning("\(line(message, detail), privacy: .public)")
        addBreadcrumb(message, level: .warning, detail: detail)
    }

    /// Log a step failure. Breadcrumbs accumulate so the terminal
    /// `report` carries every intermediate failure. The detail is what a
    /// framework or a service said of the failure, kept apart from the
    /// message: Sentry's data scrubber drops any text holding one of its
    /// sensitive words, "auth" among them, which the names of the
    /// frameworks behind a passkey hold. Kept apart, the scrubber takes
    /// only the detail, and the line saying which step failed stays.
    static func failure(_ message: String, detail: String? = nil) {
        logger.error("\(line(message, detail), privacy: .public)")
        addBreadcrumb(message, level: .error, detail: detail)
    }

    /// Capture a terminal, user-visible recovery failure as a Sentry
    /// event so the preceding breadcrumb trail is attached.
    static func report(_ message: String, kind: ReportKind) {
        logger.fault("\(message, privacy: .public)")
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.error)
            scope.setFingerprint(kind.fingerprint)
        }
    }

    /// Short non-sensitive prefix of a key id for correlating logs
    /// across devices without recording the full identifier.
    static func keyIdPrefix(_ keyId: String?) -> String {
        guard let keyId, !keyId.isEmpty else { return "nil" }
        return String(keyId.prefix(8))
    }

    /// Render an error with its underlying NSError chain (domain/code),
    /// which localizedDescription flattens away, bounded by
    /// `maxErrorChainDepth`. ASAuthorizationError codes (e.g. 1004) are
    /// only diagnosable with the domain and code intact.
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: Error? = error
        var depth = 0
        while let err = current, depth < maxErrorChainDepth {
            let nsError = err as NSError
            parts.append("\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
                ?? (err as? PasskeyError)?.underlying
            depth += 1
        }
        return parts.joined(separator: " <- ")
    }

    private static func line(_ message: String, _ detail: String?) -> String {
        detail.map { "\(message): \($0)" } ?? message
    }

    private static func addBreadcrumb(_ message: String, level: SentryLevel, detail: String? = nil) {
        // Sentry logs an error for each breadcrumb it is handed while off.
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: breadcrumbCategory)
        crumb.message = message
        if let detail { crumb.data = [breadcrumbDetailKey: detail] }
        SentrySDK.addBreadcrumb(crumb)
    }
}
