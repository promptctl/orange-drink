#!/usr/bin/env python3
# [LAW:behavior-not-structure] scripts/iphone-devices run as a process against a stand-in usbmuxd on a Unix socket, so the
# framing, the lockdown steps, the TLS switch and the capture file are held against what usbmuxd and a device send, with no
# device and no pairing. The stand-in frames its own replies with struct rather than the script's helpers, so a framing
# mistake in the script is not copied into the test.
import os
import pathlib
import plistlib
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading

SCRIPT = pathlib.Path(__file__).resolve().parent / "iphone-devices"
UDID = "00008140-000000000000001E"
DEVICE_ID = 7
LOCKDOWN_PORT, RELAY_PORT = 62078, 4321
DEVICE_VALUES = {"DeviceName": "Brandon's iPhone", "ProductType": "iPhone17,1", "ProductVersion": "27.2", "DeviceClass": "iPhone",
                 "BluetoothAddress": "6c:3a:ff:d9:74:42"}
# A control character the device sends inside a string, which a plist parser refuses until the script strips it.
RELAY_REPLY = plistlib.dumps({"Diagnostics": {"IORegistry": {"CurrentCapacity": 42, "Label": "AAA"}}}).replace(b"AAA", b"A\x01A")


def exactly(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError
        data += chunk
    return data


def mux_frame(plist):
    payload = plistlib.dumps(plist)
    return struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload


def stream_frame(payload):
    return struct.pack(">I", len(payload)) + payload


def read_stream(sock):
    return plistlib.loads(exactly(sock, struct.unpack(">I", exactly(sock, 4))[0]))


def make_identity(directory):
    """A self-signed host certificate and key: the PEM bytes go in the pair record, the paths feed the stand-in's TLS."""
    cert, key = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=host",
                    "-keyout", key, "-out", cert], check=True, capture_output=True)
    return cert, key


class StandInUsbmuxd(socketserver.StreamRequestHandler):
    """Answers the requests the script makes. self.server.devices lists the devices; self.server.paired says whether a
    pair record exists for them; self.server.fault, when set, is "connect" (usbmuxd refuses every Connect), "locked"
    (lockdown refuses StartService) or "no-entry" (the relay answers without an IORegistry entry); self.server.tls_context,
    when set, makes lockdown and the relay switch to TLS the way a device does and demand the host certificate."""

    def handle(self):
        sock = self.request
        n = struct.unpack("<I", exactly(sock, 16)[:4])[0]
        request = plistlib.loads(exactly(sock, n - 16))
        kind = request["MessageType"]
        if kind == "ListDevices":
            sock.sendall(mux_frame({"DeviceList": self.server.devices}))
        elif kind == "ReadPairRecord":
            assert request["PairRecordID"] == UDID, request
            cert, key = self.server.identity
            record = {"HostID": "host", "SystemBUID": "buid",
                      "HostCertificate": pathlib.Path(cert).read_bytes(), "HostPrivateKey": pathlib.Path(key).read_bytes()}
            sock.sendall(mux_frame({"PairRecordData": plistlib.dumps(record)} if self.server.paired else {"Number": 2}))
        elif kind == "Connect":
            assert request["DeviceID"] == DEVICE_ID, request
            sock.sendall(mux_frame({"Number": 3 if self.server.fault == "connect" else 0}))
            if self.server.fault == "connect":
                return
            port = socket.ntohs(request["PortNumber"])
            {LOCKDOWN_PORT: self.lockdown, RELAY_PORT: self.relay}[port](sock)
        else:
            raise AssertionError(f"unexpected usbmuxd request {kind}")

    def tls(self, sock):
        return self.server.tls_context.wrap_socket(sock, server_side=True)

    def lockdown(self, sock):
        encrypted = self.server.tls_context is not None
        while True:
            request = read_stream(sock)
            if request["Request"] == "StartSession":
                reply = {"SessionID": "s", "EnableSessionSSL": encrypted}
            elif request["Request"] == "GetValue":
                reply = {"Value": DEVICE_VALUES[request["Key"]]}
            elif request["Request"] == "StartService":
                assert request["Service"] == "com.apple.mobile.diagnostics_relay"
                reply = {"Error": "PasswordProtected"} if self.server.fault == "locked" else {"Port": RELAY_PORT, "EnableServiceSSL": encrypted}
            else:
                raise AssertionError(f"unexpected lockdown request {request}")
            sock.sendall(stream_frame(plistlib.dumps(reply)))
            if request["Request"] == "StartSession" and encrypted:
                sock = self.tls(sock)
            if request["Request"] == "StartService":
                return

    def relay(self, sock):
        if self.server.tls_context is not None:
            sock = self.tls(sock)
        request = read_stream(sock)
        assert request == {"Request": "IORegistry", "EntryClass": "IOPMPowerSource"}, request
        sock.sendall(stream_frame(plistlib.dumps({"Status": "Failure"}) if self.server.fault == "no-entry" else RELAY_REPLY))


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def listing(connection_type):
    return {"DeviceID": DEVICE_ID, "Properties": {"SerialNumber": UDID, "ConnectionType": connection_type}}


def run(devices, paired, *args, tls=False, fault=None):
    """The script's exit code, stdout and stderr, with a stand-in usbmuxd listing `devices`."""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "usbmuxd")
        server = Server(path, StandInUsbmuxd)
        server.devices, server.paired, server.fault = devices, paired, fault
        server.identity = make_identity(tmp)
        server.tls_context = None
        if tls:
            cert, key = server.identity
            server.tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server.tls_context.load_cert_chain(cert, key)
            server.tls_context.verify_mode = ssl.CERT_REQUIRED
            server.tls_context.load_verify_locations(cert)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            done = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), *args],
                env={"USBMUXD_SOCKET": path}, capture_output=True, text=True, timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
    return done.returncode, done.stdout, done.stderr


def check(condition, message):
    if not condition:
        sys.exit(f"FAILED: {message}")


def check_capture(connection_type, **stand_in):
    with tempfile.TemporaryDirectory() as tmp:
        captures = os.path.join(tmp, "captures")
        code, out, err = run([listing(connection_type)], True, "capture", captures, **stand_in)
        written = os.listdir(captures) if os.path.isdir(captures) else None
        check(code == 0 and written == [f"iPhone17,1-27.2-{UDID}-{connection_type}.plist"],
              f"capture should write one file named for the device, OS and connection: {code} {written} {err!r}")
        reply = plistlib.loads(pathlib.Path(captures, written[0]).read_bytes())
        check(reply["Device"] == {**DEVICE_VALUES, "ConnectionType": connection_type}, f"the file should stamp the device: {reply['Device']}")
        check(reply["Diagnostics"]["IORegistry"] == {"CurrentCapacity": 42, "Label": "AA"}, f"the relay's reply should keep its keys and lose the control character: {reply}")


def main():
    code, out, err = run([], True, "list")
    check(code == 0 and out.strip() == "0 device(s) listed", f"an empty list should print a count of 0 and exit 0: {code} {out!r} {err!r}")

    code, out, err = run([listing("USB"), listing("Network")], True, "list")
    check(code == 0 and out.count(UDID) == 2 and "'ConnectionType': 'USB'" in out and "'ConnectionType': 'Network'" in out,
          f"each listing should print its connection type and UDID: {code} {out!r} {err!r}")

    check_capture("USB")
    # Over Wi-Fi the device switches lockdown and the relay to TLS and demands the host certificate from the pair record.
    check_capture("Network", tls=True)

    with tempfile.TemporaryDirectory() as tmp:
        code, out, err = run([listing("Network")], False, "capture", tmp)
        check(code == 1 and UDID in err and "no pair record" in err and os.listdir(tmp) == [],
              f"a device that never trusted this Mac should fail loudly, name the device and write nothing: {code} {err!r}")

    # Each fault is a device that cannot be captured: the run fails with the refusal's own words, names the device, and
    # writes nothing.
    for fault, words in (("connect", "refused Connect"), ("locked", "PasswordProtected"), ("no-entry", "no IORegistry entry")):
        with tempfile.TemporaryDirectory() as tmp:
            code, out, err = run([listing("Network")], True, "capture", tmp, fault=fault)
            check(code == 1 and UDID in err and words in err and os.listdir(tmp) == [],
                  f"fault {fault!r} should fail with {words!r}, name the device and write nothing: {code} {err!r}")

    print("iphone-devices: every case held")


main()
