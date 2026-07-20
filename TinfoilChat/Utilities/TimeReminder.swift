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

    static func formatCurrentTimeReminder(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d, yyyy, hh:mm a zzz"
        let dateTime = formatter.string(from: now)
        let timezone = TimeZone.current.identifier
        return "<system-reminder>Current time: \(dateTime) (\(timezone))</system-reminder>"
    }
}
