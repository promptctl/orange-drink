# Where macOS publishes the Charge Limit (orange-alerts-cjt.c2g)

macOS 26.5.2, Charge Limit 80%.

- `charge_limit_probe.m`: PowerUI's `PowerUISmartChargeClient`, which System Settings uses, answers an unentitled caller with MCL 0, no available limits, and limit 100 synchronously, and never calls the async handler, while PowerUIAgent logs "Continue limiting to 80% for reason 'manualChargeLimit'". No IOPS key, registry key, SMC key, or readable preference holds the limit.
- `capture.swift`: one line every 30 s, IOPS beside the AppleSmartBattery registry. Charging to the limit:

```
10:15:28 pct=79 psCharging=1 psToFull=50 notChargingReason=0
10:15:58 pct=80 psCharging=1 psToFull=48 notChargingReason=16777216
10:16:28 pct=80 psCharging=1 psToFull=48 notChargingReason=16777216
10:16:58 pct=80 psCharging=0 psCharged=0 psToFull=0 notChargingReason=16777216
```

  NotChargingReason was 0 on every charging sample from 29% to 79%, and 128 on battery. IOPS's time to full counts to 100% (140 min at 31%), as `pmset -g batt` does.
- powerd's log has the same bit as SMC CHNC: "Charging Completed Limited ... CHNC:1000000" 3-8 ms after "Capacity:80" at every crossing; it stays set for a while on battery after an unplug (CHNC:1000080), for a varying time.
