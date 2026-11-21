import CoreGraphics

/// Réglages du lissage et de la fixation.
struct GazeParameters: Sendable, Equatable {
    var minCutoff: Double = 0.5
    var beta: Double = 0.002
    var derivativeCutoff: Double = 1.0
    var fixationDuration: Double = 0.15
    var fixationDispersion: Double = 120
    /// Nombre d'images du filtre médian appliqué en premier (1 = désactivé).
    /// Il supprime les sauts isolés (mauvaise détection sur une image) sans lisser les vrais mouvements.
    var medianWindow: Int = 3
    /// Stabilisation (voir `StableGazeFilter`) : seuil de saut (points), images de confirmation,
    /// mémoire de la fixation (images).
    var jumpThreshold: Double = 200
    var jumpConfirmFrames: Int = 2
    var fixationMemory: Int = 60
}

/// Estimation du regard à un instant, en points Quartz (origine haut-gauche de l'écran principal).
struct GazeEstimate: Sendable, Equatable {
    /// Sortie brute de la calibration (avec décalage de recentrage), bornée à l'écran.
    var raw: CGPoint
    /// Après filtre médian et One Euro (suit vite, mais tremble).
    var smoothed: CGPoint
    /// Point stabilisé (moyenne de la fixation en cours), quand la fixation compte assez de mesures.
    var fixation: CGPoint?
    var timestamp: Double
    /// La prédiction brute tombe nettement hors de l'écran calibré (la tête a bougé ?).
    var isOffScreen: Bool
    /// Un vrai changement de regard vient d'être confirmé à cette image (nouvelle fixation).
    var jumped: Bool = false

    /// Point à utiliser pour viser : la fixation si elle existe, sinon le point lissé.
    var point: CGPoint { fixation ?? smoothed }
}

/// Fin de la chaîne du regard : bornage à l'écran, filtre médian, puis deux sorties :
/// One Euro (point lissé, réactif) et stabilisation par fixation (point pour viser).
/// Logique pure, sans AppKit.
struct GazeEngine: Sendable {
    private(set) var parameters: GazeParameters
    private var filterX: OneEuroFilter
    private var filterY: OneEuroFilter
    private var stable: StableGazeFilter
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
        stable = StableGazeFilter()
        Self.apply(parameters, to: &stable)
    }

    private static func apply(_ p: GazeParameters, to stable: inout StableGazeFilter) {
        stable.minThreshold = p.jumpThreshold
        stable.maxThreshold = max(p.jumpThreshold * 2, p.jumpThreshold)
        stable.confirmFrames = max(p.jumpConfirmFrames, 1)
        stable.memory = max(p.fixationMemory, 2)
    }

    /// Nombre minimal de mesures dans la fixation pour la considérer comme établie.
    static let minimumFixationSamples = 4

    /// Bruit mesuré par la stabilisation (points), et nombre de sauts détectés.
    var stabilizerNoise: Double? { stable.noise }
    var jumpCount: Int { stable.jumpCount }

    mutating func setParameters(_ p: GazeParameters) {
        guard p != parameters else { return }
        parameters = p
        filterX.minCutoff = p.minCutoff; filterX.beta = p.beta; filterX.derivativeCutoff = p.derivativeCutoff
        filterY.minCutoff = p.minCutoff; filterY.beta = p.beta; filterY.derivativeCutoff = p.derivativeCutoff
        Self.apply(p, to: &stable)
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
        let jumpsBefore = stable.jumpCount
        let stabilized = stable.add(median)
        let fixation = stable.fixation.count >= Self.minimumFixationSamples ? stabilized : nil
        return GazeEstimate(raw: bounded, smoothed: smoothed, fixation: fixation,
                            timestamp: timestamp, isOffScreen: offScreen,
                            jumped: stable.jumpCount != jumpsBefore)
    }

    mutating func reset() {
        filterX.reset()
        filterY.reset()
        stable.reset()
        recent = []
        history = []
    }
}
