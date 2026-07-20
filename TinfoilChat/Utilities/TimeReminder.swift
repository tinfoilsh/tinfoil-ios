//
//  TimeReminder.swift
//  TinfoilChat
//
//  Copyright © 2026 Tinfoil. All rights reserved.

import Foundation

/// Builds the ephemeral current-time reminder appended to the end of chat
/// requests. Keeping the timestamp out of the system prompt (the first
/// message) preserves server-side prefix caching: only the tail of the
/// prompt changes between turns.
///
/// Minute granularity (no seconds) so retries and regenerations within the
/// same minute produce byte-identical requests.
enum TimeReminder {

    private static let dateFormat = "EEEE, MMMM d, yyyy, hh:mm a zzz"

    // en_US_POSIX guarantees invariant fixed-format output (QA1480): plain
    // en_US would let the user's 24-hour time override rewrite "hh:mm a".
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter
    }()

    static func formatCurrentTimeReminder(now: Date = Date()) -> String {
        let dateTime = formatter.string(from: now)
        let timezone = TimeZone.current.identifier
        return "<system-reminder>Current time: \(dateTime) (\(timezone))</system-reminder>"
    }
}
