import Foundation

enum DisplayPowerPolicy {
    static let hiddenGrace: TimeInterval = 3

    static func shouldPowerOff(
        backgroundSavingEnabled: Bool,
        hiddenFor: TimeInterval
    ) -> Bool {
        backgroundSavingEnabled && hiddenFor >= hiddenGrace
    }
}
