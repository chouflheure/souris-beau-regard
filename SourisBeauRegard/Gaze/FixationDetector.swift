import CoreGraphics

/// Détection de fixation par dispersion (I-DT).
///
/// Une fixation commence quand les points des `minDuration` dernières secondes tiennent dans une
/// dispersion (largeur + hauteur) inférieure à `maxDispersion`. Elle dure tant que les nouveaux
/// points gardent l'ensemble sous ce seuil ; son centre (moyenne de tous ses points) est stable.
struct FixationDetector: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        var point: CGPoint
        var time: Double
    }

    /// Durée minimale d'une fixation, en secondes.
    var minDuration: Double
    /// Dispersion maximale (largeur + hauteur), en points écran.
    var maxDispersion: Double
    /// Nombre maximal de points gardés pendant une fixation (environ 4 s à 30 i/s).
    var maxSamples = 120

    private(set) var samples: [Sample] = []
    private(set) var isFixating = false

    init(minDuration: Double = 0.15, maxDispersion: Double = 80) {
        self.minDuration = minDuration
        self.maxDispersion = maxDispersion
    }

    static func dispersion(_ samples: [Sample]) -> Double {
        guard let first = samples.first else { return 0 }
        var minX = first.point.x, maxX = first.point.x, minY = first.point.y, maxY = first.point.y
        for s in samples.dropFirst() {
            minX = min(minX, s.point.x); maxX = max(maxX, s.point.x)
            minY = min(minY, s.point.y); maxY = max(maxY, s.point.y)
        }
        return Double((maxX - minX) + (maxY - minY))
    }

    var centroid: CGPoint? {
        guard !samples.isEmpty else { return nil }
        let sx = samples.reduce(0) { $0 + $1.point.x }
        let sy = samples.reduce(0) { $0 + $1.point.y }
        return CGPoint(x: sx / CGFloat(samples.count), y: sy / CGFloat(samples.count))
    }

    /// Ajoute un point ; renvoie le centre de la fixation en cours, ou `nil` hors fixation.
    mutating func add(_ point: CGPoint, time: Double) -> CGPoint? {
        samples.append(Sample(point: point, time: time))

        if isFixating {
            if Self.dispersion(samples) > maxDispersion {
                // Saccade : la fixation est terminée, on repart de ce point.
                isFixating = false
                samples = [Sample(point: point, time: time)]
            } else if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }

        if !isFixating {
            // Fenêtre glissante : on retire les plus anciens jusqu'à passer sous le seuil.
            while samples.count > 1, Self.dispersion(samples) > maxDispersion {
                samples.removeFirst()
            }
            if let first = samples.first, let last = samples.last,
               last.time - first.time >= minDuration {
                isFixating = true
            }
        }
        return isFixating ? centroid : nil
    }

    mutating func reset() {
        samples = []
        isFixating = false
    }
}
