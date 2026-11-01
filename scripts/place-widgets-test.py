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
    kinds = dict(re.findall(r'case (\w+) = "(\w+)"', shelf))
    widgets = "\n".join(path.read_text() for path in (REPO / "Sources/OrangeDrinkWidgets").glob("*.swift"))
    found = re.findall(r"(?:Static|AppIntent)Configuration\(kind: WidgetKind\.(\w+)\.rawValue(?:, intent: (\w+)\.self)?", widgets)
    if not found:
        sys.exit("FAILED: no widget configuration found in Sources/OrangeDrinkWidgets")
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
        idata = actual[kind]
        named = idata is None if intent is None else idata is not None and bytes([0x40 + len(intent)]) + intent.encode() in idata
        if not named:
            sys.exit(f"FAILED: {kind} declares {intent} but is placed with {idata!r}")
    print("ok: each widget is placed with the AppIntent its source declares")
    if actual["DeviceBattery"] != RECORDED_DEVICE_INTENT:
        sys.exit(f"FAILED: DeviceBattery's idata is not what macOS writes: {actual['DeviceBattery']!r}")
    print("ok: an intent is placed in the bytes macOS writes")


main()
