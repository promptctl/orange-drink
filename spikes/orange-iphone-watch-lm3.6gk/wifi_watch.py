#!/usr/bin/env python3
"""Spike: battery health and cycle count via the diagnostics relay's IORegistry query.

Lockdown session (as in battery_session.py) -> StartService diagnostics_relay -> IORegistry
for AppleSmartBattery. Prints the battery entry's fields. Temp PEM files are removed on exit.
"""
import plistlib, re, socket, ssl, struct, sys, tempfile, os

LOCKDOWN_PORT = 62078
UDID = sys.argv[1]
DEVICE_ID = int(sys.argv[2]) if len(sys.argv) > 2 else 2
WANT = ["CycleCount", "DesignCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity",
        "MaxCapacity", "DesignCycleCount70", "Temperature", "BatteryData"]

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

def tls(sock, pair):
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
        return ctx.wrap_socket(sock)
    finally:
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)

"""Spike: sample a device's battery over Wi-Fi sync at intervals.

Usage: wifi_watch.py <UDID> <usbmux DeviceID> <samples> <seconds between samples>
Each sample opens a new lockdown session, diagnostics relay, and IORegistry query.
"""
import time
SAMPLES = int(sys.argv[3])
GAP = float(sys.argv[4])
FIELDS = ["CurrentCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity", "CycleCount"]

def one_sample(pair):
    s = mux("Connect", {"DeviceID": DEVICE_ID, "PortNumber": socket.htons(LOCKDOWN_PORT)})
    assert read_mux(s).get("Number") == 0, "lockdown connect failed"
    send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
    assert recv(s).get("EnableSessionSSL")
    s = tls(s, pair)
    send(s, {"Request": "StartService", "Service": "com.apple.mobile.diagnostics_relay"})
    svc = recv(s)
    r = mux("Connect", {"DeviceID": DEVICE_ID, "PortNumber": socket.htons(svc["Port"])})
    assert read_mux(r).get("Number") == 0, "relay connect failed"
    if svc.get("EnableServiceSSL"):
        r = tls(r, pair)
    send(r, {"Request": "IORegistry", "EntryClass": "AppleSmartBattery"})
    n = struct.unpack(">I", r.recv(4))[0]
    raw = b""
    while len(raw) < n:
        raw += r.recv(n - len(raw))
    entry = plistlib.loads(re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", raw))["Diagnostics"]["IORegistry"]
    bd = entry["BatteryData"]
    return {"CycleCount": entry.get("CycleCount"), "CurrentCapacity": bd.get("CurrentCapacity"),
            "NominalChargeCapacity": bd.get("NominalChargeCapacity"),
            "AppleRawMaxCapacity": bd.get("AppleRawMaxCapacity"), "Voltage": entry.get("Voltage"),
            "InstantAmperage": entry.get("InstantAmperage"), "IsCharging": entry.get("IsCharging")}

pair = plistlib.loads(read_mux(mux("ReadPairRecord", {"PairRecordID": UDID}))["PairRecordData"])
for i in range(SAMPLES):
    t = time.strftime("%H:%M:%S")
    try:
        print(t, one_sample(pair), flush=True)
    except Exception as e:
        print(t, "error:", type(e).__name__, e, flush=True)
    if i < SAMPLES - 1:
        time.sleep(GAP)
