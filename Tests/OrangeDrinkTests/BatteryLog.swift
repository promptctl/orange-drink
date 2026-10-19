import Foundation
import OSLog
@testable import OrangeDrink

/// The battery log from the moment of construction on. [LAW:one-source-of-truth] The one
/// capture every log assertion reads; Logger.info lines are memory-only, so `log show` cannot
/// replace it and OSLogStore in-process can.
struct BatteryLog {
    private let store: OSLogStore
    private let since: OSLogPosition

    init() throws {
        store = try OSLogStore(scope: .currentProcessIdentifier)
        since = store.position(date: Date())
    }

    func messages() throws -> [String] {
        try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                              IOKitBattery.logSubsystem, IOKitBattery.logCategory))
            .map(\.composedMessage)
    }
}
