import plistlib, socket, ssl, struct, sys, tempfile, os
LOCKDOWN_PORT = 62078
def mux(msg_type, extra=None):
    body = {"MessageType": msg_type, "ClientVersionString": "probe", "ProgName": "probe"}
    body.update(extra or {})
    payload = plistlib.dumps(body)
    s = socket.socket(socket.AF_UNIX); s.connect("/var/run/usbmuxd")
    s.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
    return s
def read_mux(s):
    hdr = s.recv(16); n = struct.unpack("<I", hdr[:4])[0]; data = b""
    while len(data) < n - 16: data += s.recv(n - 16 - len(data))
    return plistlib.loads(data)
def send(s, msg):
    p = plistlib.dumps(msg); s.sendall(struct.pack(">I", len(p)) + p)
def recv(s):
    n = struct.unpack(">I", s.recv(4))[0]; data = b""
    while len(data) < n: data += s.recv(n - len(data))
    return plistlib.loads(data)
# 1. Replay: what usbmuxd reports as connected right now (ListDevices), no Listen needed.
devs = read_mux(mux("ListDevices"))["DeviceList"]
for d in devs:
    p = d["Properties"]
    print("ListDevices entry: DeviceID", d["DeviceID"], "ConnectionType", p.get("ConnectionType"), "UDID", p.get("SerialNumber"))
usb = [d for d in devs if d["Properties"].get("ConnectionType") == "USB"]
print("USB entries:", len(usb), "Network entries:", len(devs) - len(usb))
# 2. Lockdown GetValue (no domain): key names only, and any Bluetooth-related value shape.
udid = devs[0]["Properties"]["SerialNumber"]
pair = plistlib.loads(read_mux(mux("ReadPairRecord", {"PairRecordID": udid}))["PairRecordData"])
dev_id = devs[0]["DeviceID"]
s = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(LOCKDOWN_PORT)})
assert read_mux(s).get("Number") == 0, "connect failed"
send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
start = recv(s)
print("StartSession EnableSessionSSL:", start.get("EnableSessionSSL"))
if start.get("EnableSessionSSL"):
    tmp = tempfile.mkdtemp()
    try:
        cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
        for path, data in ((cert, pair["HostCertificate"]), (key, pair["HostPrivateKey"])):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, data if isinstance(data, bytes) else data.encode()); os.close(fd)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        ctx.load_cert_chain(cert, key); s = ctx.wrap_socket(s)
    finally:
        for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)
send(s, {"Request": "GetValue"})
val = recv(s).get("Value", {})
print("lockdown top-level keys:", sorted(val.keys()) if isinstance(val, dict) else type(val))
for k in ("BluetoothAddress", "WiFiAddress", "UniqueDeviceID"):
    print(k, "present" if isinstance(val, dict) and k in val else "absent")
