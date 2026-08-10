import Carbon.HIToolbox
import HoverCore

@MainActor
final class RecordingHotKeyController {
    static let shared = RecordingHotKeyController()
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private var refs: [EventHotKeyRef?] = []

    func register() {
        guard refs.isEmpty else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let manager = Unmanaged<RecordingHotKeyController>.fromOpaque(userData)
                    .takeUnretainedValue()
                let hotKeyID = hkID.id
                Task { @MainActor in
                    switch hotKeyID {
                    case 6: manager.onStart?()
                    case 7: manager.onStop?()
                    default: break
                    }
                }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let signature = OSType(0x484F_5652)  // "HOVR"
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_6), UInt32(cmdKey),
            EventHotKeyID(signature: signature, id: 6),
            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
        ref = nil
        RegisterEventHotKey(
            UInt32(kVK_ANSI_7), UInt32(cmdKey),
            EventHotKeyID(signature: signature, id: 7),
            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
