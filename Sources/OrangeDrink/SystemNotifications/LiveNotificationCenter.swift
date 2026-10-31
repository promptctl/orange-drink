import AppKit
// AX's option keys are declared as mutable globals, and macOS never writes them.
@preconcurrency import ApplicationServices

/// [LAW:effects-at-boundaries] The one edge that calls the accessibility API.
private struct LiveElement: AccessibleElement, @unchecked Sendable {
    let element: AXUIElement

    private func read<Value>(_ attribute: String, as parse: (CFTypeRef) -> Value?) -> ElementRead<Value> {
        var value: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return ElementRead(read, value.flatMap(parse))
    }

    private func elements(_ attribute: String) -> ElementRead<[any AccessibleElement]> {
        read(attribute) { ($0 as? [AXUIElement])?.map(LiveElement.init) }
    }

    func string(_ attribute: String) -> ElementRead<String> { read(attribute) { $0 as? String } }
    var children: ElementRead<[any AccessibleElement]> { elements(kAXChildrenAttribute) }
    var windows: ElementRead<[any AccessibleElement]> { elements(kAXWindowsAttribute) }

    var actions: ElementRead<[String]> {
        var names: CFArray?
        let read = AXUIElementCopyActionNames(element, &names)
        return ElementRead(read, names as? [String])
    }

    func press(_ action: String) -> AXError { AXUIElementPerformAction(element, action as CFString) }
}

/// The closure an AXObserver calls, held for as long as it is watching.
private final class ObserverCallback {
    let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
}

extension BatteryNotificationDismissal.Effects {
    static let live = Self(
        level: { IOKitBattery.warningLevel() },
        trust: { prompt in AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary) },
        notificationCenter: { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier },
        windows: { LiveElement(element: AXUIElementCreateApplication($0)).windows },
        observe: observe,
        tables: { LowBatteryTables.read(from: LowBatteryTables.directory) })

    /// AXLayoutChanged is the event that arrives with the alert. The source is on the main run loop in every mode, so a menu
    /// being tracked does not hold it, and the callback does nothing but wake a pass.
    private static func observe(_ pid: pid_t, onChange: @escaping @Sendable () -> Void) -> Result<BatteryNotificationDismissal.Observer, BatteryNotificationDismissal.AXErrorBox> {
        var created: AXObserver?
        let creating = AXObserverCreate(pid, { _, _, _, refcon in
            Unmanaged<ObserverCallback>.fromOpaque(refcon!).takeUnretainedValue().onChange()
        }, &created)
        guard creating == .success, let observer = created else { return .failure(.init(error: creating)) }
        let callback = Unmanaged.passRetained(ObserverCallback(onChange: onChange))
        let application = AXUIElementCreateApplication(pid)
        let added = AXObserverAddNotification(observer, application, kAXLayoutChangedNotification as CFString, callback.toOpaque())
        guard added == .success else {
            callback.release()
            return .failure(.init(error: added))
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let held = HeldObserver(observer: observer, application: application, source: source, callback: callback)
        return .success(.init(pid: pid, stop: held.stop))
    }
}

/// An observation's parts, which CoreFoundation does not declare Sendable.
private struct HeldObserver: @unchecked Sendable {
    let observer: AXObserver
    let application: AXUIElement
    let source: CFRunLoopSource
    let callback: Unmanaged<ObserverCallback>

    func stop() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        AXObserverRemoveNotification(observer, application, kAXLayoutChangedNotification as CFString)
        // [LAW:no-ambient-temporal-coupling] This runs off the main thread and the callback on it, so the last reference
        // goes where no call to it can be under way.
        DispatchQueue.main.async { callback.release() }
    }
}
