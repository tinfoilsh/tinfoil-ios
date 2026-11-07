import Foundation

/// How fast replies are read aloud, as a multiple of how fast the voice
/// speaks. The account's profile keeps it.
enum ReadAloudSpeed {
    /// A speed the profile holds, or the voice's own for one this app does
    /// not offer.
    static func offered(_ speed: Double?) -> Double {
        guard let speed, Constants.Speech.speeds.contains(speed) else { return Constants.Speech.voiceSpeed }
        return speed
    }

    /// The speed a speech request for the account names, nil at the voice's
    /// own.
    @MainActor
    static func requested(_ account: HarnessAccount) -> Double? {
        let speed = offered(account.effectiveProfile.readAloudSpeed)
        return speed == Constants.Speech.voiceSpeed ? nil : speed
    }
}
