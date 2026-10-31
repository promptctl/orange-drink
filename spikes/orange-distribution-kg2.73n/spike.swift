// Spike orange-distribution-kg2.73n: where can IOBluetooth be registered without holding the main thread on the
// Bluetooth permission prompt? The bundle id's last word picks the variant; see run.sh.
import AppKit
import CoreBluetooth
import IOBluetooth

let variant = Bundle.main.bundleIdentifier!.components(separatedBy: ".").last!
let logFile = fopen("/tmp/spike-\(variant).log", "a")!
let start = Date()
func say(_ line: String) {
    fputs(String(format: "%6.1f %@ %@\n", Date().timeIntervalSince(start), Thread.isMainThread ? "main" : "off ", line), logFile)
    fflush(logFile)
}

final class Watcher: NSObject {
    @objc func connected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) { say("connect notification: \(device.name ?? "?")") }
}
let watcher = Watcher()
var held: [AnyObject] = []
func register() {
    say("registering")
    let n = IOBluetoothDevice.register(forConnectNotifications: watcher, selector: #selector(Watcher.connected(_:device:)))
    say("registered: \(n == nil ? "nil" : "a notification")")
    if let n { held.append(n) }
    say("paired: \((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.count ?? -1)")
}

final class Central: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        say("central state \(central.state.rawValue) authorization \(CBManager.authorization.rawValue)")
        if CBManager.authorization != .notDetermined { DispatchQueue.main.async(execute: register) }
    }
}

say("launched, authorization \(CBManager.authorization.rawValue)")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var beats = 0
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in beats += 1; say("beat \(beats)") }
let central = Central()
var manager: CBCentralManager?
switch variant {
case "main": DispatchQueue.main.async(execute: register)
case "pool": DispatchQueue.global().async(execute: register)
case "thread":
    Thread.detachNewThread {
        register()
        say("running the thread's run loop")
        RunLoop.current.add(Port(), forMode: .default)
        RunLoop.current.run()
    }
case "central": manager = CBCentralManager(delegate: central, queue: DispatchQueue(label: "central"))
default: fatalError("no variant \(variant)")
}
app.run()
