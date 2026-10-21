import Foundation

// The iPhone's IORegistry AppleSmartBattery reply, captured over Wi-Fi by spikes/orange-iphone-watch-lm3.8pk/capture_ioreg.py
// on the reference iPhone (ProductType iPhone16,2) and cut to the keys the parser reads. Serial numbers and the
// rest of the entry are not copied here. Expected: level 55, health 3761/4395 (86% on Settings > Battery), cycles 584.
let iPhoneBatteryReplyXML = """
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
				<key>AppleRawMaxCapacity</key>
				<integer>3908</integer>
				<key>CurrentCapacity</key>
				<integer>55</integer>
				<key>DesignCapacity</key>
				<integer>4395</integer>
				<key>NominalChargeCapacity</key>
				<integer>3761</integer>
			</dict>
			<key>CycleCount</key>
			<integer>584</integer>
		</dict>
	</dict>
</dict>
</plist>

"""

// The iPad's reply, captured over Wi-Fi by capture_ioreg.py (DeviceClass iPad) and cut to the keys the parser reads.
// Its layout is .topLevel: CycleCount, CurrentCapacity, AppleRawMaxCapacity top-level; DesignCapacity in BatteryData.
// Expected: level 87, no health (no nominal capacity on this layout), cycles 395, design 9633 mAh.
let iPadBatteryReplyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Diagnostics</key>
	<dict>
		<key>IORegistry</key>
		<dict>
			<key>AppleRawMaxCapacity</key>
			<integer>8506</integer>
			<key>BatteryData</key>
			<dict>
				<key>DesignCapacity</key>
				<integer>9633</integer>
			</dict>
			<key>CurrentCapacity</key>
			<integer>87</integer>
			<key>CycleCount</key>
			<integer>395</integer>
		</dict>
	</dict>
</dict>
</plist>

"""
