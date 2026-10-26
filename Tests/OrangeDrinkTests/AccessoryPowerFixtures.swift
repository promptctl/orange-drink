import Foundation

// Power management's accessory sources, cut to the keys AccessoryPower.levels(from:) reads, as
// IOPSCopyPowerSourcesByType(4) returned them on this Mac on 2026-10-26 (orange-devices-bue.1e6). FluffPods
// (AirPods Max) and CMF Buds were connected; c-pods (AirPods Pro, its left bud charging in a case at 1%) and
// ear-pluggers (in their case) were nearby and not connected. Expected: FluffPods 47, CMF Buds 60 (no Group
// Identifier), c-pods Left 28 + Case 1, ear-pluggers Left 100 + Right 100 (a Combined source) + Case 100.
let accessorySourcesXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>Current Capacity</key>
		<integer>47</integer>
		<key>Group Identifier</key>
		<string>B6D01D7C-D93D-4B30-9B45-C26EDD448EF6</string>
		<key>Max Capacity</key>
		<integer>100</integer>
		<key>Name</key>
		<string>FluffPods</string>
		<key>Part Identifier</key>
		<string>Single</string>
		<key>Type</key>
		<string>Accessory Source</string>
	</dict>
	<dict>
		<key>Current Capacity</key>
		<integer>1</integer>
		<key>Group Identifier</key>
		<string>E359AC50-2520-48B9-83BA-115F4A80B469</string>
		<key>Max Capacity</key>
		<integer>100</integer>
		<key>Name</key>
		<string>c-pods Case</string>
		<key>Part Identifier</key>
		<string>Case</string>
		<key>Type</key>
		<string>Accessory Source</string>
	</dict>
	<dict>
		<key>Current Capacity</key>
		<integer>28</integer>
		<key>Group Identifier</key>
		<string>E359AC50-2520-48B9-83BA-115F4A80B469</string>
		<key>Max Capacity</key>
		<integer>100</integer>
		<key>Name</key>
		<string>c-pods</string>
		<key>Part Identifier</key>
		<string>Left</string>
		<key>Type</key>
		<string>Accessory Source</string>
	</dict>
	<dict>
		<key>Current Capacity</key>
		<integer>60</integer>
		<key>Max Capacity</key>
		<integer>100</integer>
		<key>Name</key>
		<string>CMF Buds</string>
		<key>Part Identifier</key>
		<string>Single</string>
		<key>Type</key>
		<string>Accessory Source</string>
	</dict>
	<dict>
		<key>Current Capacity</key>
		<integer>100</integer>
		<key>Group Identifier</key>
		<string>07E7EB87-FFB8-4200-9F8D-42AA51BE472C</string>
		<key>Max Capacity</key>
		<integer>100</integer>
		<key>Name</key>
		<string>ear-pluggers Case</string>
		<key>Part Identifier</key>
		<string>Case</string>
		<key>Type</key>
		<string>Accessory Source</string>
	</dict>
	<dict>
		<key>Combined Parts</key>
		<array>
			<dict>
				<key>Current Capacity</key>
				<integer>100</integer>
				<key>Group Identifier</key>
				<string>07E7EB87-FFB8-4200-9F8D-42AA51BE472C</string>
				<key>Max Capacity</key>
				<integer>100</integer>
				<key>Name</key>
				<string>ear-pluggers</string>
				<key>Part Identifier</key>
				<string>Left</string>
				<key>Type</key>
				<string>Accessory Source</string>
			</dict>
			<dict>
				<key>Current Capacity</key>
				<integer>100</integer>
				<key>Group Identifier</key>
				<string>07E7EB87-FFB8-4200-9F8D-42AA51BE472C</string>
				<key>Max Capacity</key>
				<integer>100</integer>
				<key>Name</key>
				<string>ear-pluggers</string>
				<key>Part Identifier</key>
				<string>Right</string>
				<key>Type</key>
				<string>Accessory Source</string>
			</dict>
		</array>
		<key>Current Capacity</key>
		<integer>100</integer>
		<key>Group Identifier</key>
		<string>07E7EB87-FFB8-4200-9F8D-42AA51BE472C</string>
		<key>Max Capacity</key>
		<integer>100</integer>
		<key>Name</key>
		<string>ear-pluggers</string>
		<key>Part Identifier</key>
		<string>Combined</string>
		<key>Type</key>
		<string>Accessory Source</string>
	</dict>
</array>
</plist>

"""
