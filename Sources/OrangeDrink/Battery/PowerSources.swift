import Foundation
import IOKit.ps

/// [LAW:one-source-of-truth] The one walk over a copy of powerd's power sources: the Mac's own battery
/// (`IOKitBattery`) and the accessories (`AccessoryPower`) read the same list, copied by different calls.
enum PowerSources {
    /// Each source's description in a copy `call` made. Both steps answer nil, not an error, when powerd
    /// is unreachable, so the error names the call that answered nil.
    static func descriptions(_ copy: Unmanaged<CFTypeRef>?, copiedBy call: String) throws -> [[String: Any]] {
        guard let info = copy?.takeRetainedValue() else { throw PowerSourcesError.unanswered(call: call) }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            throw PowerSourcesError.unanswered(call: "IOPSCopyPowerSourcesList")
        }
        return (list as [CFTypeRef]).compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}

enum PowerSourcesError: Error, Equatable {
    /// powerd returned nothing from the named IOPowerSources call.
    case unanswered(call: String)
}
