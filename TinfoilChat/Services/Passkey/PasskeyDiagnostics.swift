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

    /// Log a flow milestone (which path was taken, candidate counts).
    static func step(_ message: String) {
        logger.info("\(message, privacy: .public)")
        addBreadcrumb(message, level: .info)
    }

    /// Log a non-fatal anomaly worth seeing in a report.
    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        addBreadcrumb(message, level: .warning)
    }

    /// Log a step failure. Breadcrumbs accumulate so the terminal
    /// `report` carries every intermediate failure.
    static func failure(_ message: String) {
        logger.error("\(message, privacy: .public)")
        addBreadcrumb(message, level: .error)
    }

    /// Capture a terminal, user-visible recovery failure as a Sentry
    /// event so the preceding breadcrumb trail is attached.
    static func report(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.error)
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

    private static func addBreadcrumb(_ message: String, level: SentryLevel) {
        let crumb = Breadcrumb(level: level, category: "passkey")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }
}
