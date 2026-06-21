//
//  AccessibilityAnnouncer.swift
//  TinfoilChat
//
//  VoiceOver status announcements (live-region equivalent)
//

import UIKit

/// Posts VoiceOver announcements for transient status changes that have no
/// persistent on-screen control to focus, such as a response starting,
/// finishing, or being stopped. This mirrors the web app's aria-live region.
enum AccessibilityAnnouncer {
    /// Speaks `message` through VoiceOver. No-ops when VoiceOver is not
    /// running so non-assistive-tech users are unaffected.
    static func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }

        // High priority keeps the status cue from being dropped while
        // VoiceOver is mid-utterance reading streamed content.
        let announcement = NSAttributedString(
            string: message,
            attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high]
        )
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}
