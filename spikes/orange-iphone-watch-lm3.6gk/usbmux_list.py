#!/usr/bin/env python3
"""Spike: talk to macOS usbmuxd over /var/run/usbmuxd and list attached/Wi-Fi-sync iOS devices.

usbmuxd frame: <u32 len><u32 version=1><u32 type=8 plist><u32 tag> + XML plist.
"""
import plistlib, socket, struct, sys

def request(msg_type, extra=None):
    body = {"MessageType": msg_type, "ClientVersionString": "spike", "ProgName": "spike"}
    body.update(extra or {})
    payload = plistlib.dumps(body)
    s = socket.socket(socket.AF_UNIX)
    s.connect("/var/run/usbmuxd")
    s.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
    return s

def read_frame(s):
    hdr = s.recv(16)
    if len(hdr) < 16:
        return None
    n = struct.unpack("<I", hdr[:4])[0]
    data = b""
    while len(data) < n - 16:
        data += s.recv(n - 16 - len(data))
    return plistlib.loads(data)

if __name__ == "__main__":
    s = request("ListDevices")
    print(read_frame(s))
