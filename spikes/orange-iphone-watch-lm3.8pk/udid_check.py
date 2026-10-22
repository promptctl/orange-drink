# Prints True when lockdown UniqueDeviceID equals the usbmux UDID (verified this session). Run from this directory: python3 -I udid_check.py
import plistlib, socket, ssl, struct, tempfile, os
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_mux.py")).read().split("# 1. Replay")[0])
devs = read_mux(mux("ListDevices"))["DeviceList"]
udid = devs[0]["Properties"]["SerialNumber"]; dev_id = devs[0]["DeviceID"]
pair = plistlib.loads(read_mux(mux("ReadPairRecord", {"PairRecordID": udid}))["PairRecordData"])
s = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(LOCKDOWN_PORT)}); read_mux(s)
send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]}); recv(s)
tmp = tempfile.mkdtemp(); cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
for path, data in ((cert, pair["HostCertificate"]), (key, pair["HostPrivateKey"])):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, data if isinstance(data, bytes) else data.encode()); os.close(fd)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
ctx.load_cert_chain(cert, key); s = ctx.wrap_socket(s)
for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
os.rmdir(tmp)
send(s, {"Request": "GetValue", "Key": "UniqueDeviceID"}); u = recv(s).get("Value")
print("UniqueDeviceID equals pair-record/usbmux UDID:", u == udid, "| UniqueDeviceID is str:", isinstance(u, str))
