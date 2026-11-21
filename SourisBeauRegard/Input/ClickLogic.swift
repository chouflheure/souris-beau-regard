import CoreGraphics

/// Événement de souris à envoyer (coordonnées Quartz).
enum MouseAction: Sendable, Equatable {
    case move(CGPoint)
    case leftDown(CGPoint, clickState: Int)
    case leftDragged(CGPoint)
    case leftUp(CGPoint, clickState: Int)
    case rightDown(CGPoint)
    case rightUp(CGPoint)
}

/// Traduit les appuis de la touche de clic en événements de souris. Logique pure, testée.
///
/// - appui puis relâchement sans mouvement du regard : clic gauche au centre de la cible ;
/// - regard qui s'éloigne pendant l'appui : glisser-déposer qui suit le regard lissé ;
/// - deux appuis rapprochés (temps et distance) : double-clic (`clickState` = 2, puis 3) ;
/// - Contrôle tenu à l'appui : clic droit.
struct ClickLogic: Sendable, Equatable {
    var doubleClickInterval: Double = 0.3
    var doubleClickDistance: CGFloat = 30
    /// Distance du regard au point d'appui au-delà de laquelle l'appui devient un glisser (points).
    var dragThreshold: CGFloat = 80

    private(set) var isPressed = false
    private(set) var isDragging = false
    private var isSecondary = false
    private var pressPoint: CGPoint = .zero
    private var dragPoint: CGPoint = .zero
    private var clickState = 0
    private var lastClickTime = -Double.infinity
    private var lastClickPoint: CGPoint = .zero

    mutating func press(at point: CGPoint, time: Double, secondary: Bool) -> [MouseAction] {
        guard !isPressed else { return [] }
        isPressed = true
        isDragging = false
        isSecondary = secondary
        pressPoint = point
        dragPoint = point
        if secondary {
            return [.move(point), .rightDown(point)]
        }
        let close = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) <= doubleClickDistance
        clickState = (time - lastClickTime <= doubleClickInterval && close) ? min(clickState + 1, 3) : 1
        // Un double-clic garde exactement le point du premier clic.
        if clickState > 1 { pressPoint = lastClickPoint }
        lastClickTime = time
        lastClickPoint = pressPoint
        return [.move(pressPoint), .leftDown(pressPoint, clickState: clickState)]
    }

    /// Regard (lissé) pendant l'appui.
    mutating func gazeMoved(to point: CGPoint) -> [MouseAction] {
        guard isPressed, !isSecondary else { return [] }
        if !isDragging, hypot(point.x - pressPoint.x, point.y - pressPoint.y) > dragThreshold {
            isDragging = true
        }
        guard isDragging else { return [] }
        dragPoint = point
        return [.leftDragged(point)]
    }

    mutating func release(time: Double) -> [MouseAction] {
        guard isPressed else { return [] }
        isPressed = false
        if isSecondary {
            return [.rightUp(pressPoint)]
        }
        if isDragging {
            isDragging = false
            lastClickTime = -Double.infinity   // un glisser ne compte pas pour un double-clic
            return [.leftUp(dragPoint, clickState: 1)]
        }
        return [.leftUp(pressPoint, clickState: clickState)]
    }

    /// Arrêt d'urgence : relâche le bouton s'il est enfoncé.
    mutating func cancel() -> [MouseAction] {
        guard isPressed else { return [] }
        return release(time: -Double.infinity)
    }
}

/// Historique court de points horodatés (regard), pour prendre la position d'avant l'appui.
struct PointHistory: Sendable, Equatable {
    var maxAge: Double = 1.0
    private(set) var entries: [(time: Double, point: CGPoint)] = []

    static func == (a: PointHistory, b: PointHistory) -> Bool {
        a.maxAge == b.maxAge && a.entries.map { $0.time } == b.entries.map { $0.time }
            && a.entries.map { $0.point } == b.entries.map { $0.point }
    }

    mutating func record(_ point: CGPoint, at time: Double) {
        entries.append((time, point))
        while entries.count > 1, entries[1].time < time - maxAge { entries.removeFirst() }
    }

    /// Dernier point enregistré au plus tard à `time`.
    func point(at time: Double) -> CGPoint? {
        entries.last(where: { $0.time <= time })?.point
    }
}

/// Codes des touches de modification et masque « par côté » correspondant dans les drapeaux d'un
/// `CGEvent` (permet de distinguer Option droite d'Option gauche). Logique pure, testée.
enum KeyCodes {
    static let rightOption: Int64 = 61
    static let leftOption: Int64 = 58
    static let rightCommand: Int64 = 54
    static let leftCommand: Int64 = 55
    static let rightControl: Int64 = 62
    static let leftControl: Int64 = 59
    static let rightShift: Int64 = 60
    static let leftShift: Int64 = 56
    static let function: Int64 = 63

    /// Masque du côté de la touche dans `CGEventFlags.rawValue`, ou `nil` si ce n'est pas une touche
    /// de modification.
    static func deviceMask(for keyCode: Int64) -> UInt64? {
        switch keyCode {
        case leftControl: 0x0000_0001
        case leftShift: 0x0000_0002
        case rightShift: 0x0000_0004
        case leftCommand: 0x0000_0008
        case rightCommand: 0x0000_0010
        case leftOption: 0x0000_0020
        case rightOption: 0x0000_0040
        case rightControl: 0x0000_2000
        case function: 0x0080_0000
        default: nil
        }
    }

    /// La touche de modification est-elle enfoncée d'après les drapeaux ?
    static func isPressed(keyCode: Int64, flags: UInt64) -> Bool? {
        deviceMask(for: keyCode).map { flags & $0 != 0 }
    }

    /// Touches proposées dans les réglages.
    static let choices: [(code: Int64, name: String)] = [
        (rightOption, "Option droite"),
        (rightCommand, "Commande droite"),
        (rightControl, "Contrôle droit"),
        (function, "Fn"),
        (105, "F13"),
        (107, "F14"),
    ]

    static func name(for code: Int64) -> String {
        choices.first { $0.code == code }?.name ?? "Touche \(code)"
    }
}
