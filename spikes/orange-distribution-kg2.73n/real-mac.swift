// Spike orange-distribution-kg2.73n, on a Mac with devices connected: does a registration made off the main thread
// hear the connects IOBluetooth replays for connected devices? Reads the authorization first and stops unless it is
// already allowed, so it cannot raise a prompt on a Mac in use.
//   swiftc -O -swift-version 5 real-mac.swift -framework IOBluetooth -framework CoreBluetooth -o /tmp/real-mac && /tmp/real-mac <main|pool|thread|central>
import CoreBluetooth
import Foundation
import IOBluetooth

guard CBManager.authorization == .allowedAlways else { print("authorization \(CBManager.authorization.rawValue): not allowed, stopping"); exit(2) }
final class Watcher: NSObject {
    @objc func connected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        print("connect \(device.addressString ?? "?") on \(Thread.isMainThread ? "main" : Thread.current.description)")
    }
}
let watcher = Watcher()
var held: IOBluetoothUserNotification?
func register() {
    held = IOBluetoothDevice.register(forConnectNotifications: watcher, selector: #selector(Watcher.connected(_:device:)))
    print("registered from \(Thread.isMainThread ? "main" : "off main"): \(held == nil ? "nil" : "a notification")")
}
final class Answers: NSObject, CBCentralManagerDelegate {
    let made = Date()
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("state \(central.state.rawValue) authorization \(CBManager.authorization.rawValue) after \(Date().timeIntervalSince(made) * 1000) ms")
    }
}
let answers = Answers()
var central: CBCentralManager?
switch CommandLine.arguments[1] {
case "main": register()
case "pool": DispatchQueue.global().async(execute: register)
case "thread":
    Thread.detachNewThread { register(); RunLoop.current.add(Port(), forMode: .default); RunLoop.current.run() }
case "central":
    let began = Date()
    central = CBCentralManager(delegate: answers, queue: DispatchQueue(label: "central"), options: [CBCentralManagerOptionShowPowerAlertKey: false])
    print("central made in \(Date().timeIntervalSince(began) * 1000) ms")
default: fatalError()
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))
print("connected now: \((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }.count)")
