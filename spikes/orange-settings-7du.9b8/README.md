# Spike orange-settings-7du.9b8

Can the app language change take effect without a restart? `./run.sh` builds `Spike.app` (a String Catalog with en and fr compiled into its Resources, like the real bundle) and runs it twice, with the Mac set to en and to fr. `output.txt` is the last run. SwiftUI surfaces are read back by rendering offscreen and recognising the text; nothing is shown or captured on screen.
