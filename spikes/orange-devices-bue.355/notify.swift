// Spike .355 part 2: change notification + poll cost.
// Run: swiftc -O notify.swift -framework IOBluetooth -o /tmp/notify && /tmp/notify
import Foundation
import IOBluetooth

final class Watcher: NSObject {
    var disconnects: [IOBluetoothUserNotification] = []
    @objc func connected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        print("EVENT connect \(device.name ?? "?")")
        disconnects.append(device.register(forDisconnectNotification: self, selector: #selector(gone(_:device:))))
    }
    @objc func gone(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) { print("EVENT disconnect \(device.name ?? "?")") }
}
let w = Watcher()
let reg = IOBluetoothDevice.register(forConnectNotifications: w, selector: #selector(Watcher.connected(_:device:)))
// Already-connected devices don't replay as connect events: seed from pairedDevices().
for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where d.isConnected() {
    w.disconnects.append(d.register(forDisconnectNotification: w, selector: #selector(Watcher.gone(_:device:))))
}

// Cost of one full poll of every paired device's battery.
let t0 = CFAbsoluteTimeGetCurrent(), cpu0 = clock()
for _ in 0..<200 {
    for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where d.isConnected() {
        _ = d.value(forKey: "batteryPercentSingle"); _ = d.value(forKey: "batteryPercentLeft")
        _ = d.value(forKey: "batteryPercentRight"); _ = d.value(forKey: "batteryPercentCase")
    }
}
let per = (CFAbsoluteTimeGetCurrent() - t0) / 200
print(String(format: "poll: %.2f ms wall, %.2f ms cpu per sweep", per * 1000, Double(clock() - cpu0) / Double(CLOCKS_PER_SEC) / 200 * 1000))
print(String(format: "=> at one sweep/60s: %.5f%% CPU", Double(clock() - cpu0) / Double(CLOCKS_PER_SEC) / 200 / 60 * 100))
_ = reg
