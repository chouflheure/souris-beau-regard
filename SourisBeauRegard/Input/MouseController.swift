import CoreGraphics

/// Envoie les événements de souris (coordonnées Quartz).
///
/// - drapeaux de modification remis à zéro sur chaque événement, sinon le clic deviendrait un
///   Option-clic (la touche de clic est encore tenue) ;
/// - chaque événement est marqué (`eventSourceUserData`) pour que l'apprentissage par les clics
///   ignore nos propres clics.
enum MouseController {
    /// Marque de nos événements (« SBRG »).
    static let marker: Int64 = 0x5342_5247

    static func perform(_ actions: [MouseAction]) {
        for action in actions { perform(action) }
    }

    static func perform(_ action: MouseAction) {
        switch action {
        case .move(let p):
            post(.mouseMoved, at: p, button: .left)
        case .leftDown(let p, let state):
            post(.leftMouseDown, at: p, button: .left, clickState: state)
        case .leftDragged(let p):
            post(.leftMouseDragged, at: p, button: .left)
        case .leftUp(let p, let state):
            post(.leftMouseUp, at: p, button: .left, clickState: state)
        case .rightDown(let p):
            post(.rightMouseDown, at: p, button: .right, clickState: 1)
        case .rightUp(let p):
            post(.rightMouseUp, at: p, button: .right, clickState: 1)
        }
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int? = nil) {
        // Source « privée » : n'hérite pas de l'état des touches de modification du clavier.
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = []
        if let clickState { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
}
