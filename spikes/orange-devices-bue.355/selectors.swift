import Foundation
import IOBluetooth
var n: UInt32 = 0
let ms = class_copyMethodList(IOBluetoothDevice.self, &n)!
for i in 0..<Int(n) { let s = NSStringFromSelector(method_getName(ms[i])); if s.lowercased().contains("batt") { print(s) } }
for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where d.isConnected() {
  for k in ["batteryPercentCase","batteryPercentLeft","batteryPercentRight","batteryPercentSingle","batteryPercentCombined"] { print(k, d.value(forKey: k) ?? "nil") }
}
