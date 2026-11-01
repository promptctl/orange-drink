#!/usr/bin/env python3
# [LAW:behavior-not-structure] What scripts/place-widgets writes, decoded with no VM: each widget is placed with the AppIntent
# the app's source gives its kind, in the bytes macOS itself writes, because a widget placed without one never draws on macOS 14.
import pathlib
import plistlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
APP = "dev.orangedrink.OrangeDrink"
# macOS 14.8.7's own CHSIntentReference `idata` for a Device Battery widget dragged from the gallery.
RECORDED_DEVICE_INTENT = (
    b"\xe4HlaunchId[dev.orangedrink.OrangeDrinkKisAppIntent\x01"
    b"SappIntentIdentifierRSelectDeviceIntentTserializedParameters\xe0"
)


def declared():
    """Each widget kind's AppIntent as the source declares it, None for a kind with none: {"MacBattery": None, ...}."""
    shelf = (REPO / "Sources/Shared/WidgetShelf.swift").read_text()
    kinds = dict(re.findall(r'case (\w+) = "(\w+)"', re.search(r"enum WidgetKind.*?\n}", shelf, re.DOTALL).group()))
    widgets = "\n".join(path.read_text() for path in (REPO / "Sources/OrangeDrinkWidgets").rglob("*.swift"))
    found = re.findall(r"(?:Static|AppIntent)Configuration\(kind: WidgetKind\.(\w+)\.rawValue(?:, intent: (\w+)\.self)?", widgets)
    if {case for case, _ in found} != set(kinds):
        sys.exit(f"FAILED: WidgetKind has {sorted(kinds)} but Sources/OrangeDrinkWidgets reads as {sorted(found)}")
    return {kinds[case]: intent or None for case, intent in found}


def placed():
    """Each placed widget's kind and its intent's `idata`, None for a widget with no intent."""
    output = subprocess.run([REPO / "scripts/place-widgets", APP], capture_output=True, check=True).stdout
    widgets = {}
    for instance in plistlib.loads(output)["instances"]:
        objects = plistlib.loads(plistlib.loads(instance)["widget"])["$objects"]
        root = objects[1]
        intent = objects[root["intent2"].data]
        widgets[objects[root["kind"].data]] = None if intent == "$null" else objects[intent["idata"].data]
    return widgets


def main():
    expected, actual = declared(), placed()
    if set(expected) != set(actual):
        sys.exit(f"FAILED: the source declares {sorted(expected)} but place-widgets places {sorted(actual)}")
    print("ok: every widget the extension declares is placed")
    for kind, intent in expected.items():
        written = intent and RECORDED_DEVICE_INTENT.replace(b"RSelectDeviceIntent", bytes([0x40 + len(intent)]) + intent.encode())
        if actual[kind] != written:
            sys.exit(f"FAILED: {kind} declares {intent}, which macOS writes as {written!r}, but is placed with {actual[kind]!r}")
    print("ok: each widget is placed with the AppIntent its source declares, in the bytes macOS writes")
    waited = re.search(r"^kinds='(.+)'$", (REPO / "scripts/widget-click-check").read_text(), re.MULTILINE).group(1).split()
    if set(waited) != set(actual):
        sys.exit(f"FAILED: scripts/widget-click-check waits on {sorted(waited)} but place-widgets places {sorted(actual)}")
    print("ok: the click check waits on every placed widget")
    if subprocess.run([REPO / "scripts/place-widgets", "x" * 33], capture_output=True).returncode == 0:
        sys.exit("FAILED: place-widgets wrote 33 bytes under an OPACK tag that holds 32")
    print("ok: text OPACK's tag cannot hold is refused")


main()
