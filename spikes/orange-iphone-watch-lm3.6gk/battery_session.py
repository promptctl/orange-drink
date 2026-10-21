#!/usr/bin/env python3
"""Spike: battery values over a lockdown session (TLS with the pairing record's host cert).

Prints only the battery values, never pairing material. Temp PEM files are removed on exit.
"""
import plistlib, socket, ssl, struct, sys, tempfile, os

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

def send(s, msg):
    p = plistlib.dumps(msg)
    s.sendall(struct.pack(">I", len(p)) + p)

def recv(s):
    n = struct.unpack(">I", s.recv(4))[0]
    data = b""
    while len(data) < n:
        data += s.recv(n - len(data))
    return plistlib.loads(data)

rec = read_mux(mux("ReadPairRecord", {"PairRecordID": UDID}))
pair = plistlib.loads(rec["PairRecordData"])

s = mux("Connect", {"DeviceID": DEVICE_ID, "PortNumber": socket.htons(LOCKDOWN_PORT)})
assert read_mux(s).get("Number") == 0, "connect failed"

send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
start = recv(s)
print("StartSession keys:", sorted(start.keys()), "EnableSessionSSL:", start.get("EnableSessionSSL"))

if start.get("EnableSessionSSL"):
    tmp = tempfile.mkdtemp()
    try:
        cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
        for path, data in ((cert, pair["HostCertificate"]), (key, pair["HostPrivateKey"])):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
            os.write(fd, data if isinstance(data, bytes) else data.encode())
            os.close(fd)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.load_cert_chain(cert, key)
        s = ctx.wrap_socket(s)
    finally:
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)

send(s, {"Request": "GetValue", "Domain": "com.apple.mobile.battery"})
value = recv(s).get("Value", {})
print("battery domain keys:", sorted(value.keys()) if isinstance(value, dict) else value)
print("battery values:", value)

# Probe candidate keys for health and cycle count, one GetValue per key, same session.
CANDIDATES = ["CycleCount", "DesignCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity",
              "MaximumCapacityPercent", "Temperature", "BatteryHealth", "AppleRawCurrentCapacity"]
for key in CANDIDATES:
    send(s, {"Request": "GetValue", "Domain": "com.apple.mobile.battery", "Key": key})
    print(f"probe {key}:", recv(s).get("Value", "<no value>"))
