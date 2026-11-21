import CoreGraphics

/// Réglages du lissage et de la fixation.
struct GazeParameters: Sendable, Equatable {
    var minCutoff: Double = 0.8
    var beta: Double = 0.006
    var derivativeCutoff: Double = 1.0
    var fixationDuration: Double = 0.15
    var fixationDispersion: Double = 80
}

/// Estimation du regard à un instant, en points Quartz (origine haut-gauche de l'écran principal).
struct GazeEstimate: Sendable, Equatable {
    /// Sortie brute de la calibration (avec décalage de recentrage), bornée à l'écran.
    var raw: CGPoint
    /// Après filtre One Euro.
    var smoothed: CGPoint
    /// Centre de la fixation en cours, s'il y en a une.
    var fixation: CGPoint?
    var timestamp: Double

    /// Point à utiliser pour viser : la fixation si elle existe, sinon le point lissé.
    var point: CGPoint { fixation ?? smoothed }
}

/// Fin de la chaîne du regard : bornage à l'écran, filtre One Euro sur x et y, puis fixation.
/// Logique pure, sans AppKit.
struct GazeEngine: Sendable {
    private(set) var parameters: GazeParameters
    private var filterX: OneEuroFilter
    private var filterY: OneEuroFilter
    private var fixation: FixationDetector

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

    mutating func process(raw: CGPoint, timestamp: Double, bounds: CGRect?) -> GazeEstimate {
        let bounded = bounds.map { Self.clamp(raw, to: $0) } ?? raw
        let smoothed = CGPoint(x: filterX.filter(Double(bounded.x), timestamp: timestamp),
                               y: filterY.filter(Double(bounded.y), timestamp: timestamp))
        let center = fixation.add(smoothed, time: timestamp)
        return GazeEstimate(raw: bounded, smoothed: smoothed, fixation: center, timestamp: timestamp)
    }

    mutating func reset() {
        filterX.reset()
        filterY.reset()
        fixation.reset()
    }
}
