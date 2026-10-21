#!/usr/bin/env python3
"""Spike: read battery values from a trusted iPhone through usbmuxd + lockdown.

Steps: ReadPairRecord from usbmuxd, Connect to lockdown port 62078, GetValue on the
com.apple.mobile.battery domain. Plain lockdown framing: u32 big-endian length + XML plist.
"""
import plistlib, socket, struct, sys

LOCKDOWN_PORT = 62078
UDID = sys.argv[1]
DEVICE_ID = int(sys.argv[2]) if len(sys.argv) > 2 else 2

def mux(msg_type, extra=None):
    body = {"MessageType": msg_type, "ClientVersionString": "spike", "ProgName": "spike"}
    body.update(extra or {})
    payload = plistlib.dumps(body)
    s = socket.socket(socket.AF_UNIX)
    s.connect("/var/run/usbmuxd")
    s.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
    return s

def read_mux(s):
    hdr = s.recv(16)
    n = struct.unpack("<I", hdr[:4])[0]
    data = b""
    while len(data) < n - 16:
        data += s.recv(n - 16 - len(data))
    return plistlib.loads(data)

def lockdown_send(s, msg):
    payload = plistlib.dumps(msg)
    s.sendall(struct.pack(">I", len(payload)) + payload)

def lockdown_recv(s):
    n = struct.unpack(">I", s.recv(4))[0]
    data = b""
    while len(data) < n:
        data += s.recv(n - len(data))
    return plistlib.loads(data)

# 1. Pairing record from usbmuxd
s = mux("ReadPairRecord", {"PairRecordID": UDID})
rec = read_mux(s)
print("ReadPairRecord:", {k: (v if not isinstance(v, bytes) else f"<{len(v)} bytes>") for k, v in rec.items()})
pair = plistlib.loads(rec["PairRecordData"]) if "PairRecordData" in rec else None
print("pair record keys:", sorted(pair.keys()) if pair else None)

# 2. Connect to lockdown on the device
s = mux("Connect", {"DeviceID": DEVICE_ID, "PortNumber": socket.htons(LOCKDOWN_PORT)})
res = read_mux(s)
print("Connect result:", res)
if res.get("Number") != 0:
    sys.exit("connect failed")

# 3. Query type, then battery values
lockdown_send(s, {"Request": "QueryType"})
print("QueryType:", lockdown_recv(s))
lockdown_send(s, {"Request": "GetValue", "Domain": "com.apple.mobile.battery"})
print("GetValue battery:", lockdown_recv(s))
