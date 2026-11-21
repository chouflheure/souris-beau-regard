import CoreGraphics

/// Stabilisation du regard pour viser : pendant une fixation, on donne la **moyenne** de toutes les
/// mesures depuis son début (2 s au plus), ce qui divise le bruit ; on ne repart de zéro que sur un vrai
/// saut du regard.
///
/// Le bruit d'une webcam « dérive » (il est corrélé d'une image à l'autre) : un simple seuil sur la
/// dispersion se déclenche sans cesse et fait sautiller le point. Ici, un saut est confirmé seulement
/// si la moyenne des `window` dernières mesures s'écarte du centre de la fixation de plus que
/// `threshold` pendant `confirmFrames` images de suite. Le seuil s'adapte au bruit mesuré.
/// Logique pure, testée.
struct StableGazeFilter: Sendable, Equatable {
    /// Images de la fenêtre courte comparée au centre de la fixation.
    var window = 4
    /// Seuil de saut minimal et maximal (points).
    var minThreshold: Double = 200
    var maxThreshold: Double = 400
    /// Seuil = `noiseFactor` × bruit de la moyenne de la fenêtre courte, borné par les valeurs ci-dessus.
    /// 4 plutôt que 3 : le bruit étant corrélé, la moyenne de 4 images le réduit moins que prévu
    /// (simulation : fausses détections divisées par 20, sans retard supplémentaire).
    var noiseFactor: Double = 4
    /// Images consécutives au-delà du seuil pour confirmer un saut.
    var confirmFrames = 2
    /// Mesures gardées dans la fixation (60 ≈ 2 s à 30 i/s) : permet de suivre une dérive lente.
    var memory = 60

    private(set) var fixation: [CGPoint] = []
    private var recent: [CGPoint] = []
    private var noiseVariance: Double?
    private var breaches = 0
    /// Nombre de sauts détectés depuis la création (diagnostic).
    private(set) var jumpCount = 0

    /// Bruit mesuré d'une image (écart quadratique moyen au centre de la fixation, points).
    var noise: Double? { noiseVariance.map { $0.squareRoot() } }

    var threshold: Double {
        let perWindow = (noise ?? 0) / Double(max(window, 1)).squareRoot()
        return min(max(minThreshold, noiseFactor * perWindow), maxThreshold)
    }

    static func mean(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let n = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    /// Ajoute une mesure ; renvoie le point stabilisé.
    mutating func add(_ p: CGPoint) -> CGPoint {
        guard p.x.isFinite, p.y.isFinite else { return Self.mean(fixation) }
        recent.append(p)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        guard !fixation.isEmpty else {
            fixation = [p]
            return p
        }
        let center = Self.mean(fixation)
        let recentMean = Self.mean(recent)
        let gap = Double(hypot(recentMean.x - center.x, recentMean.y - center.y))
        breaches = (recent.count == window && gap > threshold) ? breaches + 1 : 0

        if breaches >= confirmFrames {
            // Saut confirmé : nouvelle fixation à partir des mesures les plus récentes.
            fixation = Array(recent.suffix(max(window / 2, 1)))
            breaches = 0
            jumpCount += 1
        } else {
            let d2 = Double((p.x - center.x) * (p.x - center.x) + (p.y - center.y) * (p.y - center.y))
            noiseVariance = noiseVariance.map { 0.97 * $0 + 0.03 * d2 } ?? d2
            fixation.append(p)
            if fixation.count > memory { fixation.removeFirst(fixation.count - memory) }
        }
        return Self.mean(fixation)
    }

    mutating func reset() {
        fixation = []
        recent = []
        breaches = 0
    }
}
