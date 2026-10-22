#!/usr/bin/env python3
# Captures the cleaned IORegistry AppleSmartBattery reply of the first USB device (or the first device) to a file
# given as the argument, as an XML plist. Same lockdown and relay flow as spikes/orange-iphone-watch-lm3.6gk/battery_ioreg.py.
# Run from this directory: python3 -I capture_ioreg.py /tmp/ioreg-<device>.plist
# The file holds the full reply, serial numbers included: keep it outside the repo and commit only the allowlisted keys.
import os, plistlib, re, socket, ssl, struct, sys, tempfile

exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_mux.py")).read().split("# 1. Replay")[0])
out_path = sys.argv[1]

devs = read_mux(mux("ListDevices"))["DeviceList"]
usb = [d for d in devs if d["Properties"].get("ConnectionType") == "USB"]
d = usb[0] if usb else devs[0]
udid, dev_id = d["Properties"]["SerialNumber"], d["DeviceID"]
print("device:", d["Properties"].get("ConnectionType"))
pair = plistlib.loads(read_mux(mux("ReadPairRecord", {"PairRecordID": udid}))["PairRecordData"])

s = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(LOCKDOWN_PORT)}); read_mux(s)
send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
if recv(s).get("EnableSessionSSL"):
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
send(s, {"Request": "GetValue", "Key": "DeviceClass"}); print("DeviceClass:", recv(s).get("Value"))
send(s, {"Request": "StartService", "Service": "com.apple.mobile.diagnostics_relay"})
svc = recv(s)
r = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(svc["Port"])}); read_mux(r)
if svc.get("EnableServiceSSL"):
    tmp = tempfile.mkdtemp()
    try:
        cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
        for path, data in ((cert, pair["HostCertificate"]), (key, pair["HostPrivateKey"])):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, data if isinstance(data, bytes) else data.encode()); os.close(fd)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        ctx.load_cert_chain(cert, key); r = ctx.wrap_socket(r)
    finally:
        for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)
send(r, {"Request": "IORegistry", "EntryClass": "AppleSmartBattery"})
n = struct.unpack(">I", r.recv(4))[0]
raw = b""
while len(raw) < n: raw += r.recv(n - len(raw))
clean = re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", raw)
reply = plistlib.loads(clean)
with open(out_path, "wb") as f: f.write(plistlib.dumps(reply, fmt=plistlib.FMT_XML))
print("wrote reply with top-level keys:", sorted(reply["Diagnostics"]["IORegistry"].keys()))
