#!/usr/bin/env python3
# Captures the cleaned IORegistry IOPMPowerSource reply of every device usbmuxd lists (cable or Wi-Fi) into the directory
# given as the argument, one XML plist per listing, named <ProductType>-<ProductVersion>-<udid>-<ConnectionType>.plist
# (a device on both cable and Wi-Fi is listed, and captured, twice). Each file holds the relay reply plus a top-level "Device" dict (ProductType, ProductVersion, DeviceClass, ConnectionType) so a fixture cut
# from it can name the device and OS it came from. Same lockdown and relay flow as spikes/orange-iphone-watch-lm3.6gk/battery_ioreg.py.
# IOPMPowerSource, not AppleSmartBattery: the Vision Pro answers only to the superclass (orange-iphone-watch-lm3.7iy cmt-9996a69e).
# Run from this directory: python3 -I capture_ioreg.py /tmp/lm3.7iy/captures
# The files hold the full reply, serial numbers included: keep them outside the repo and commit only the allowlisted keys.
import os, plistlib, re, socket, ssl, struct, sys, tempfile

exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_mux.py")).read().split("# 1. Replay")[0])
out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)

def wrap_tls(sock, pair):
    tmp = tempfile.mkdtemp()
    try:
        cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
        for path, data in ((cert, pair["HostCertificate"]), (key, pair["HostPrivateKey"])):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, data if isinstance(data, bytes) else data.encode()); os.close(fd)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        ctx.load_cert_chain(cert, key); return ctx.wrap_socket(sock)
    finally:
        for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)

def capture(d):
    udid, dev_id, conn = d["Properties"]["SerialNumber"], d["DeviceID"], d["Properties"].get("ConnectionType")
    record = read_mux(mux("ReadPairRecord", {"PairRecordID": udid}))
    if "PairRecordData" not in record:
        raise RuntimeError(f"{udid} ({conn}): no pair record, the device has not trusted this Mac: {record}")
    pair = plistlib.loads(record["PairRecordData"])
    s = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(LOCKDOWN_PORT)}); read_mux(s)
    send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]})
    if recv(s).get("EnableSessionSSL"): s = wrap_tls(s, pair)
    device = {"ConnectionType": conn}
    for key in ("ProductType", "ProductVersion", "DeviceClass"):
        send(s, {"Request": "GetValue", "Key": key}); device[key] = recv(s)["Value"]
    send(s, {"Request": "StartService", "Service": "com.apple.mobile.diagnostics_relay"})
    svc = recv(s)
    r = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(svc["Port"])}); read_mux(r)
    if svc.get("EnableServiceSSL"): r = wrap_tls(r, pair)
    send(r, {"Request": "IORegistry", "EntryClass": "IOPMPowerSource"})
    n = struct.unpack(">I", r.recv(4))[0]
    raw = b""
    while len(raw) < n: raw += r.recv(n - len(raw))
    reply = plistlib.loads(re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", raw))
    reply["Device"] = device
    path = os.path.join(out_dir, f"{device['ProductType']}-{device['ProductVersion']}-{udid}-{conn}.plist")
    with open(path, "wb") as f: f.write(plistlib.dumps(reply, fmt=plistlib.FMT_XML))
    entry = reply.get("Diagnostics", {}).get("IORegistry")
    print(path, device, "entry keys:", len(entry) if entry else f"NO ENTRY: {reply}")

failed = 0
for d in read_mux(mux("ListDevices"))["DeviceList"]:
    try: capture(d)
    except Exception as e: failed += 1; print("FAILED", d["Properties"].get("SerialNumber"), repr(e), file=sys.stderr)
sys.exit(1 if failed else 0)
