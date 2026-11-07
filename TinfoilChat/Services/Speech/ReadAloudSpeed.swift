import Foundation

/// How fast replies are read aloud on this device, as a multiple of how fast
/// the voice speaks.
enum ReadAloudSpeed {
    /// The speed this device reads aloud at: one of Constants.Speech.speeds.
    static var current: Double {
        let stored = UserDefaults.standard.double(forKey: Constants.StorageKeys.Settings.readAloudSpeed)
        return Constants.Speech.speeds.contains(stored) ? stored : Constants.Speech.voiceSpeed
    }

    /// The speed a speech request names, nil at the voice's own.
    static var requested: Double? {
        let speed = current
        return speed == Constants.Speech.voiceSpeed ? nil : speed
    }
}
