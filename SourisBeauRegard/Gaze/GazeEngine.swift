import CoreGraphics

/// Réglages du lissage et de la fixation.
struct GazeParameters: Sendable, Equatable {
    var minCutoff: Double = 0.5
    var beta: Double = 0.002
    var derivativeCutoff: Double = 1.0
    var fixationDuration: Double = 0.15
    var fixationDispersion: Double = 120
    /// Nombre d'images du filtre médian appliqué avant le One Euro (1 = désactivé).
    /// Il supprime les sauts isolés (mauvaise détection sur une image) sans lisser les vrais mouvements.
    var medianWindow: Int = 5
}

/// Estimation du regard à un instant, en points Quartz (origine haut-gauche de l'écran principal).
struct GazeEstimate: Sendable, Equatable {
    /// Sortie brute de la calibration (avec décalage de recentrage), bornée à l'écran.
    var raw: CGPoint
    /// Après filtre médian et One Euro.
    var smoothed: CGPoint
    /// Centre de la fixation en cours, s'il y en a une.
    var fixation: CGPoint?
    var timestamp: Double
    /// La prédiction brute tombe nettement hors de l'écran calibré (la tête a bougé ?).
    var isOffScreen: Bool

    /// Point à utiliser pour viser : la fixation si elle existe, sinon le point lissé.
    var point: CGPoint { fixation ?? smoothed }
}

/// Fin de la chaîne du regard : bornage à l'écran, filtre médian, filtre One Euro sur x et y,
/// puis fixation. Logique pure, sans AppKit.
struct GazeEngine: Sendable {
    private(set) var parameters: GazeParameters
    private var filterX: OneEuroFilter
    private var filterY: OneEuroFilter
    private var fixation: FixationDetector
    private var recent: [CGPoint] = []
    /// Dernières positions brutes (environ 1 s) pour mesurer le bruit.
    private var history: [CGPoint] = []
    private static let historyLength = 30

    /// Marge hors écran tolérée avant de signaler « hors écran », en fraction de l'écran.
    static let offScreenMargin: CGFloat = 0.05

    init(parameters: GazeParameters = GazeParameters()) {
        self.parameters = parameters
        filterX = OneEuroFilter(minCutoff: parameters.minCutoff, beta: parameters.beta,
                                derivativeCutoff: parameters.derivativeCutoff)
        filterY = filterX
        fixation = FixationDetector(minDuration: parameters.fixationDuration,
                                    maxDispersion: parameters.fixationDispersion)
    }

    mutating func setParameters(_ p: GazeParameters) {
        guard p != parameters else { return }
        parameters = p
        filterX.minCutoff = p.minCutoff; filterX.beta = p.beta; filterX.derivativeCutoff = p.derivativeCutoff
        filterY.minCutoff = p.minCutoff; filterY.beta = p.beta; filterY.derivativeCutoff = p.derivativeCutoff
        fixation.minDuration = p.fixationDuration
        fixation.maxDispersion = p.fixationDispersion
    }

    static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX),
                y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    static func isFinite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }

    /// Écart-type (points) des positions brutes de la dernière seconde : le « bruit » du regard.
    var rawSpread: Double? {
        guard history.count >= 5 else { return nil }
        let n = CGFloat(history.count)
        let mx = history.reduce(0) { $0 + $1.x } / n
        let my = history.reduce(0) { $0 + $1.y } / n
        let v = history.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) + ($1.y - my) * ($1.y - my) } / n
        return Double(v.squareRoot())
    }

    /// Traite une prédiction. Renvoie `nil` (et ne touche à rien) si elle n'est pas un nombre fini :
    /// une seule valeur NaN bloquerait sinon les filtres pour toujours.
    mutating func process(raw: CGPoint, timestamp: Double, bounds: CGRect?) -> GazeEstimate? {
        guard Self.isFinite(raw), timestamp.isFinite else { return nil }
        var offScreen = false
        var bounded = raw
        if let bounds {
            let margin = bounds.insetBy(dx: -bounds.width * Self.offScreenMargin,
                                        dy: -bounds.height * Self.offScreenMargin)
            offScreen = !margin.contains(raw)
            bounded = Self.clamp(raw, to: bounds)
        }

        history.append(bounded)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }

        recent.append(bounded)
        let window = max(parameters.medianWindow, 1)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        let median = CGPoint(x: Stats.median(recent.map { Double($0.x) }),
                             y: Stats.median(recent.map { Double($0.y) }))

        let smoothed = CGPoint(x: filterX.filter(Double(median.x), timestamp: timestamp),
                               y: filterY.filter(Double(median.y), timestamp: timestamp))
        let center = fixation.add(smoothed, time: timestamp)
        return GazeEstimate(raw: bounded, smoothed: smoothed, fixation: center,
                            timestamp: timestamp, isOffScreen: offScreen)
    }

    mutating func reset() {
        filterX.reset()
        filterY.reset()
        fixation.reset()
        recent = []
        history = []
    }
}
