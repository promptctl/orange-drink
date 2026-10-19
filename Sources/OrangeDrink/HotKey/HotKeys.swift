import Carbon.HIToolbox

/// A registered hot key, until it is cancelled.
@MainActor protocol HotKeyRegistration: AnyObject {
    func cancel()
}

/// The Mac's global hot keys: a combination that fires whichever app is frontmost.
///
/// [LAW:effects-at-boundaries] What a press does is decided by `OpenPanelHotKey`; this is the one
/// place the system is asked to deliver it.
@MainActor protocol HotKeys {
    /// [LAW:no-silent-failure] Throws when the system will not register the combination, for example
    /// because another app holds it.
    func register(_ combo: KeyCombo, fire: @escaping @MainActor () -> Void) throws -> any HotKeyRegistration
}

struct HotKeyError: Error, CustomStringConvertible {
    /// The combination refused; nil when the system would not take the handler that delivers any of them.
    let combo: KeyCombo?
    let status: OSStatus
    var description: String {
        "the system would not \(combo.map { "register \($0.display)" } ?? "deliver hot keys") (OSStatus \(status))"
    }
}

/// The hot keys of a Mac whose system would not take the handler: every registration is refused the same way,
/// so the Shortcuts screen can say so instead of there being no screen.
struct UnavailableHotKeys: HotKeys {
    let cause: HotKeyError

    func register(_ combo: KeyCombo, fire: @escaping @MainActor () -> Void) throws -> any HotKeyRegistration {
        throw HotKeyError(combo: combo, status: cause.status)
    }
}

/// Hot keys through Carbon's RegisterEventHotKey: no Accessibility permission, and the press is
/// delivered to this app whichever app is frontmost.
@MainActor final class CarbonHotKeys: HotKeys {
    private static let signature: OSType = 0x4F44484B   // 'ODHK'

    /// [LAW:no-shared-mutable-globals] The system delivers every hot key press to one application
    /// handler, so the process has one registrar, made on first use; this is its only owner.
    private static var installed: CarbonHotKeys?

    static func shared() throws -> CarbonHotKeys {
        if let installed { return installed }
        let made = try CarbonHotKeys()
        installed = made
        return made
    }

    private var fires: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private init() throws {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr else { return read }
            let registrar = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application events on the main thread.
            return MainActor.assumeIsolated {
                guard id.signature == CarbonHotKeys.signature, let fire = registrar.fires[id.id] else { return OSStatus(eventNotHandledErr) }
                fire()
                return noErr
            }
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyError(combo: nil, status: status) }
    }

    func register(_ combo: KeyCombo, fire: @escaping @MainActor () -> Void) throws -> any HotKeyRegistration {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.carbon, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotKeyError(combo: combo, status: status) }
        fires[id] = fire
        return Registration(owner: self, id: id, ref: ref)
    }

    private final class Registration: HotKeyRegistration {
        let owner: CarbonHotKeys
        let id: UInt32
        let ref: EventHotKeyRef

        init(owner: CarbonHotKeys, id: UInt32, ref: EventHotKeyRef) {
            self.owner = owner
            self.id = id
            self.ref = ref
        }

        func cancel() {
            UnregisterEventHotKey(ref)
            owner.fires[id] = nil
        }
    }
}
