import CoreGraphics

/// Ce qu'une source de clic signale : appui (avec ou sans demande de clic droit) et relâchement.
enum ClickSourceEvent: Sendable, Equatable {
    case press(secondary: Bool)
    case release
}

/// Une façon de déclencher le clic sur la cible : touche du clavier (V1), puis pincement des doigts
/// et fixation prolongée (étape 6), derrière le même protocole.
@MainActor
protocol ClickSource: AnyObject {
    var onEvent: ((ClickSourceEvent) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Démarre la source ; `false` si c'est impossible (autorisation manquante…).
    @discardableResult func start() -> Bool
    func stop()
}
