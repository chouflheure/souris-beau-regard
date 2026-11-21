import Carbon.HIToolbox

/// Raccourcis clavier globaux (API Carbon `RegisterEventHotKey`) : ils marchent quelle que soit
/// l'app au premier plan et ne demandent aucune autorisation. Le raccourci n'est pas tapé dans l'app
/// active. Le clic par touche (étape 4) passera, lui, par un `CGEventTap`.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    struct Shortcut: Sendable, Equatable {
        var keyCode: UInt32
        /// Combinaison de `cmdKey`, `optionKey`, `controlKey`, `shiftKey` (Carbon).
        var modifiers: UInt32
        /// Texte affiché, par exemple « ⌃⌥R ».
        var label: String
    }

    static let recenter = Shortcut(keyCode: UInt32(kVK_ANSI_R),
                                   modifiers: UInt32(controlKey | optionKey), label: "⌃⌥R")
    /// Arrêt d'urgence : coupe l'interception de la touche, relâche la souris, éteint la caméra.
    static let emergencyStop = Shortcut(keyCode: UInt32(kVK_Escape),
                                        modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘Échap")

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var nextID: UInt32 = 1

    /// Enregistre un raccourci ; renvoie `false` s'il est déjà pris par une autre app.
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5342_5247), id: id) // « SBRG »
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Fonction C sans contexte : elle retrouve l'instance partagée. Carbon l'appelle sur le fil principal.
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr else { return result }
            let id = hotKeyID.id
            MainActor.assumeIsolated { GlobalHotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}
