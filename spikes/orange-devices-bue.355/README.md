# Spike orange-devices-bue.355

Prototype probes for reading paired Bluetooth devices' batteries. Build and run commands are at the top of each file.

- `probe.swift`: lists paired devices with name, type, and battery via IOBluetooth's private battery properties, plus the IORegistry `BatteryPercent` path for HID peripherals.
- `selectors.swift`: lists the private battery selectors on `IOBluetoothDevice` and dumps each connected device's values.
- `notify.swift`: connect/disconnect notifications and the cost of one battery sweep.
