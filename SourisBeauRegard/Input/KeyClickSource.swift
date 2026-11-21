import CoreGraphics
import Foundation

/// Clic par une touche du clavier, interceptée par un `CGEventTap` actif (keyDown, keyUp, flagsChanged)
/// puis **avalée** pour ne rien taper. La souris réelle n'est jamais interceptée.
///
/// Le tap est ajouté à la boucle du fil principal : son callback s'exécute sur le fil principal et ne
/// fait presque rien (comparer un code de touche, prévenir l'état central), sinon macOS le désactive
/// (`tapDisabledByTimeout`) ; on le réactive quand cela arrive.
@MainActor
final class KeyClickSource: ClickSource {
    var onEvent: ((ClickSourceEvent) -> Void)?
    /// Code de la touche de clic (Option droite par défaut).
    var keyCode: Int64 = KeyCodes.rightOption
    /// La touche n'est interceptée que si ceci renvoie `true` (suivi actif) ; sinon elle passe normalement.
    var isActive: (@MainActor () -> Bool)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: keyClickTapCallback, userInfo: refcon) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
        isRunning = false
        if isDown {
            isDown = false
            onEvent?(.release)
        }
    }

    /// Décide du sort d'un événement clavier ; `true` : l'avaler.
    fileprivate func process(typeRaw: UInt32, keyCode: Int64, flags: UInt64, isRepeat: Bool) -> Bool {
        if typeRaw == CGEventType.tapDisabledByTimeout.rawValue || typeRaw == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard keyCode == self.keyCode else { return false }
        guard isActive?() ?? true else {
            if isDown { isDown = false; onEvent?(.release) }
            return false
        }
        let control = flags & CGEventFlags.maskControl.rawValue != 0 && keyCode != KeyCodes.rightControl
        if typeRaw == CGEventType.flagsChanged.rawValue, let pressed = KeyCodes.isPressed(keyCode: keyCode, flags: flags) {
            if pressed, !isDown {
                isDown = true
                onEvent?(.press(secondary: control))
            } else if !pressed, isDown {
                isDown = false
                onEvent?(.release)
            }
            return true
        }
        if typeRaw == CGEventType.keyDown.rawValue {
            if !isRepeat, !isDown {
                isDown = true
                onEvent?(.press(secondary: control))
            }
            return true
        }
        if typeRaw == CGEventType.keyUp.rawValue {
            if isDown {
                isDown = false
                onEvent?(.release)
            }
            return true
        }
        return false
    }
}

/// Callback C du tap : extrait des valeurs simples de l'événement puis décide sur le fil principal
/// (le tap est sur la boucle du fil principal, d'où `assumeIsolated`).
private func keyClickTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let source = Unmanaged<KeyClickSource>.fromOpaque(refcon).takeUnretainedValue()
    let typeRaw = type.rawValue
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let swallow = MainActor.assumeIsolated {
        source.process(typeRaw: typeRaw, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
