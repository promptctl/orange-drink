import Foundation

// IORegistry battery replies cut to the keys parseIPhoneBattery reads, from captures by
// spikes/orange-iphone-watch-lm3.8pk/capture_ioreg.py or a public dump. Serial numbers and the rest of each entry are
// not copied here. Each header names the device, OS and source, and the values the parse must give.

// iPhone16,2 (iPhone 15 Pro Max), iOS 27.2, captured over Wi-Fi 2026-10-22 by capture_ioreg.py (IOPMPowerSource).
// Capacities only in BatteryData. Expected: level 25, design 4395 and nominal 3761 from BatteryData, cycles 584,
// max capacity 86 (Settings showed 86%, cmt-a2f429b6).
let iPhone16_2_iOS27ReplyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Diagnostics</key>
	<dict>
		<key>IORegistry</key>
		<dict>
			<key>BatteryData</key>
			<dict>
				<key>CurrentCapacity</key>
				<integer>25</integer>
				<key>DesignCapacity</key>
				<integer>4395</integer>
				<key>NominalChargeCapacity</key>
				<integer>3761</integer>
			</dict>
			<key>BatteryPackCount</key>
			<integer>1</integer>
			<key>CurrentCapacity</key>
			<integer>25</integer>
			<key>CycleCount</key>
			<integer>584</integer>
			<key>MaxCapacity</key>
			<integer>100</integer>
		</dict>
	</dict>
</dict>
</plist>

"""

// iPhone17,1 (iPhone 16 Pro), iOS 18.2, captured over Wi-Fi 2026-10-22 by capture_ioreg.py (IOPMPowerSource).
// Capacities at the top level; DesignCapacity in both places. Expected: level 8, design 3544 and nominal 3637 from the
// top level, cycles 16, max capacity 100 (the ratio is 102.6%; Settings showed 100%, cmt-04c5ee7d).
let iPhone17_1_iOS18ReplyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Diagnostics</key>
	<dict>
		<key>IORegistry</key>
		<dict>
			<key>BatteryData</key>
			<dict>
				<key>DesignCapacity</key>
				<integer>3544</integer>
			</dict>
			<key>CurrentCapacity</key>
			<integer>8</integer>
			<key>CycleCount</key>
			<integer>16</integer>
			<key>DesignCapacity</key>
			<integer>3544</integer>
			<key>MaxCapacity</key>
			<integer>100</integer>
			<key>NominalChargeCapacity</key>
			<integer>3637</integer>
		</dict>
	</dict>
</dict>
</plist>

"""

// An iPad, model and OS not recorded, captured over Wi-Fi 2026-10-21 by capture_ioreg.py's earlier AppleSmartBattery
// request. Capacities at the top level. Expected: level 87, design 9633 and nominal 8648 from the top level, cycles 395,
// max capacity 90.
let iPadOlderReplyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Diagnostics</key>
	<dict>
		<key>IORegistry</key>
		<dict>
			<key>BatteryData</key>
			<dict>
				<key>DesignCapacity</key>
				<integer>9633</integer>
			</dict>
			<key>CurrentCapacity</key>
			<integer>87</integer>
			<key>CycleCount</key>
			<integer>395</integer>
			<key>DesignCapacity</key>
			<integer>9633</integer>
			<key>MaxCapacity</key>
			<integer>100</integer>
			<key>NominalChargeCapacity</key>
			<integer>8648</integer>
		</dict>
	</dict>
</dict>
</plist>

"""

// iPad13,4 (iPad Pro 11-inch, 3rd generation), iPadOS 27.0: the public dump in github.com/darrylmorley/whatbattery/issues/1,
// requested as AppleSmartBattery. Capacities only in BatteryData. Expected: level 32, design 7596 and nominal 6891 from
// BatteryData, cycles 580, max capacity 91.
let iPad13_4_iPadOS27ReplyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Diagnostics</key>
	<dict>
		<key>IORegistry</key>
		<dict>
			<key>BatteryData</key>
			<dict>
				<key>CurrentCapacity</key>
				<integer>32</integer>
				<key>DesignCapacity</key>
				<integer>7596</integer>
				<key>NominalChargeCapacity</key>
				<integer>6891</integer>
			</dict>
			<key>BatteryPackCount</key>
			<integer>1</integer>
			<key>CurrentCapacity</key>
			<integer>32</integer>
			<key>CycleCount</key>
			<integer>580</integer>
			<key>MaxCapacity</key>
			<integer>100</integer>
		</dict>
	</dict>
</dict>
</plist>

"""

// RealityDevice14,1 (Apple Vision Pro), visionOS 27.2, captured by cable 2026-10-22 by capture_ioreg.py (IOPMPowerSource;
// the AppleSmartBattery request returns no entry). BatteryData.CurrentCapacity is mAh (2730) where the top level is
// percent (100). Expected: level 100, design 3060 and nominal 2700 from the top level, cycles 209, stored max capacity 93,
// shown over the 88% the capacities give.
let visionPro_visionOS27ReplyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Diagnostics</key>
	<dict>
		<key>IORegistry</key>
		<dict>
			<key>BatteryData</key>
			<dict>
				<key>CurrentCapacity</key>
				<integer>2730</integer>
				<key>DesignCapacity</key>
				<integer>3060</integer>
				<key>NominalChargeCapacity</key>
				<integer>2700</integer>
			</dict>
			<key>BatteryHealthData</key>
			<dict>
				<key>BatteryHealthMaxCapacity</key>
				<integer>93</integer>
			</dict>
			<key>CurrentCapacity</key>
			<integer>100</integer>
			<key>CycleCount</key>
			<integer>209</integer>
			<key>DesignCapacity</key>
			<integer>3060</integer>
			<key>MaxCapacity</key>
			<integer>100</integer>
			<key>NominalChargeCapacity</key>
			<integer>2700</integer>
		</dict>
	</dict>
</dict>
</plist>

"""
