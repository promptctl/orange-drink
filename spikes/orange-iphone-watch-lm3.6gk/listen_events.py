#!/usr/bin/env python3
"""Spike: stream usbmuxd Attached/Detached events for a fixed time window.

Prints one line per event with the time, event type, device id, connection type, and serial.
"""
import plistlib, socket, struct, sys, time

WINDOW = float(sys.argv[1]) if len(sys.argv) > 1 else 120.0

def mux(msg_type):
    body = {"MessageType": msg_type, "ClientVersionString": "spike", "ProgName": "spike"}
    payload = plistlib.dumps(body)
    s = socket.socket(socket.AF_UNIX)
    s.connect("/var/run/usbmuxd")
    s.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
    return s

def read_frame(s):
    hdr = s.recv(16)
    n = struct.unpack("<I", hdr[:4])[0]
    data = b""
    while len(data) < n - 16:
        data += s.recv(n - 16 - len(data))
    return plistlib.loads(data)

s = mux("Listen")
print("Listen result:", read_frame(s), flush=True)
s.settimeout(1.0)
end = time.time() + WINDOW
while time.time() < end:
    try:
        ev = read_frame(s)
    except socket.timeout:
        continue
    if not ev:
        break
    p = ev.get("Properties", {})
    print(time.strftime("%H:%M:%S"), ev.get("MessageType"), ev.get("DeviceID"),
          p.get("ConnectionType"), p.get("SerialNumber") or p.get("USBSerialNumber"), flush=True)
print("window closed", flush=True)
