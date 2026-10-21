#!/usr/bin/env python3
"""Spike: turn on a cabled device's Wi-Fi sync from the Mac, then read it back.

Lockdown session as in battery_session.py, then SetValue / GetValue on
com.apple.mobile.wireless_lockdown key EnableWifiConnections. Temp PEM files removed on exit.
"""
import plistlib, socket, ssl, struct, sys, tempfile, os

LOCKDOWN_PORT = 62078
UDID = sys.argv[1]
DEVICE_ID = int(sys.argv[2])
DOMAIN = "com.apple.mobile.wireless_lockdown"
KEY = "EnableWifiConnections"

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

pair = plistlib.loads(read_mux(mux("ReadPairRecord", {"PairRecordID": UDID}))["PairRecordData"])
s = mux("Connect", {"DeviceID": DEVICE_ID, "PortNumber": socket.htons(LOCKDOWN_PORT)})
assert read_mux(s).get("Number") == 0, "connect failed"
send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
assert recv(s).get("EnableSessionSSL")
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

send(s, {"Request": "GetValue", "Domain": DOMAIN, "Key": KEY})
print("before:", recv(s))
send(s, {"Request": "SetValue", "Domain": DOMAIN, "Key": KEY, "Value": True})
print("set:", recv(s))
send(s, {"Request": "GetValue", "Domain": DOMAIN, "Key": KEY})
print("after:", recv(s))
