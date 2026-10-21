# Prints whether lockdown BluetoothAddress matches the iPhone's Mac Bluetooth row, and which device owns it (bigrig; verified this session). Run from this directory: python3 -I bluetooth_check.py
import plistlib, socket, ssl, struct, tempfile, os, subprocess, re
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_mux.py")).read().split("# 1. Replay")[0])
devs = read_mux(mux("ListDevices"))["DeviceList"]
udid = devs[0]["Properties"]["SerialNumber"]; dev_id = devs[0]["DeviceID"]
pair = plistlib.loads(read_mux(mux("ReadPairRecord", {"PairRecordID": udid}))["PairRecordData"])
s = mux("Connect", {"DeviceID": dev_id, "PortNumber": socket.htons(LOCKDOWN_PORT)}); read_mux(s)
send(s, {"Request": "StartSession", "HostID": pair["HostID"], "SystemBUID": pair["SystemBUID"]}); start = recv(s)
tmp = tempfile.mkdtemp()
cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
for path, data in ((cert, pair["HostCertificate"]), (key, pair["HostPrivateKey"])):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, data if isinstance(data, bytes) else data.encode()); os.close(fd)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
ctx.load_cert_chain(cert, key); s = ctx.wrap_socket(s)
for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
os.rmdir(tmp)
send(s, {"Request": "GetValue", "Key": "BluetoothAddress"})
bt = recv(s).get("Value")
norm = lambda a: a.lower().replace("-", ":")
sp = subprocess.run(["system_profiler", "SPBluetoothDataType"], capture_output=True, text=True).stdout
block = sp.split("Brandon’s iPhone:")[1].split("\n    ")[0] if "Brandon’s iPhone:" in sp else ""
addrs = [norm(a) for a in re.findall(r"Address: ([0-9A-Fa-f:]{17})", sp.split("Brandon’s iPhone:")[1].split("\n        ", 1)[0] + sp.split("Brandon’s iPhone:")[1][:600])]
print("BluetoothAddress type:", type(bt).__name__, "format ok:", bool(re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", norm(str(bt)))))
print("matches an address under 'Brandon’s iPhone' in system_profiler:", norm(str(bt)) in addrs)
print("lockdown address appears anywhere in system_profiler output:", norm(str(bt)) in sp.lower())
print("Brandon’s iPhone block address count:", len(addrs))
lines = sp.splitlines()
i = next(n for n, l in enumerate(lines) if "Brandon’s iPhone:" in l)
iphone_addr = norm(re.search(r"([0-9A-Fa-f:]{17})", lines[i + 1]).group(1))
print("lockdown BluetoothAddress equals Brandon’s iPhone row address:", norm(str(bt)) == iphone_addr)
target = norm(str(bt))
owner = None
for l in lines:
    s_ = l.strip()
    if l.startswith("          ") and not l.startswith("              ") and s_.endswith(":"):
        owner = s_
    if target in l.lower():
        print("lockdown address is the Address of device block:", owner, "| line kind:", "Address" if "Address" in l else "other")
