import Foundation
import OSLog
@testable import OrangeDrink

/// The battery log from the moment of construction on. [LAW:one-source-of-truth] The one
/// capture every log assertion reads; Logger.info lines are memory-only, so `log show` cannot
/// replace it and OSLogStore in-process can.
struct BatteryLog {
    private let store: OSLogStore
    private let since: OSLogPosition
    private let category: String

    init(category: String = IOKitBattery.logCategory) throws {
        self.category = category
        store = try OSLogStore(scope: .currentProcessIdentifier)
        since = store.position(date: Date())
    }

    func messages() throws -> [String] {
        try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                              IOKitBattery.logSubsystem, category))
            .map(\.composedMessage)
    }

    /// Polls the log until a line contains `fragment`: log entries reach OSLogStore shortly after they are written.
    func logged(_ fragment: String) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
            if try messages().contains(where: { $0.contains(fragment) }) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
