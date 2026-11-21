import CoreGraphics

/// Déroulé de la calibration : positions des points, durées, tri des mesures. Logique pure.
struct CalibrationPlan: Sendable, Equatable {
    /// Durée d'affichage de chaque point (il rétrécit pendant ce temps).
    var pointDuration: Double = 1.5
    /// Fenêtre de mesures gardées, en secondes depuis l'apparition du point.
    var collectionStart: Double = 0.6
    var collectionEnd: Double = 1.5
    /// Ouverture minimale des yeux (en dessous : clignement).
    var minOpenness: Double = 0.15
    /// Une mesure plus loin de la médiane que `outlierFactor` × distance médiane est écartée.
    var outlierFactor: Double = 3

    /// Marge des points de calibration, en fraction de l'écran.
    static let margin: CGFloat = 0.08

    /// Grille 3×3 à 8 % des bords, en coordonnées normalisées (0…1, origine haut-gauche).
    static var calibrationGrid: [CGPoint] {
        let values: [CGFloat] = [margin, 0.5, 1 - margin]
        return values.flatMap { y in values.map { x in CGPoint(x: x, y: y) } }
    }

    /// 5 points de validation : centre et quatre points intermédiaires (différents de la grille).
    static let validationPoints: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.27, y: 0.28),
        CGPoint(x: 0.73, y: 0.28),
        CGPoint(x: 0.27, y: 0.72),
        CGPoint(x: 0.73, y: 0.72),
    ]

    static func calibrationPoints<G: RandomNumberGenerator>(using generator: inout G) -> [CGPoint] {
        calibrationGrid.shuffled(using: &generator)
    }

    /// Une mesure brute horodatée depuis l'apparition du point.
    struct TimedSample: Sendable, Equatable {
        var elapsed: Double
        var features: GazeFeatures
        var openness: Double
    }

    /// Garde les mesures de la fenêtre utile, sans clignements ni valeurs aberrantes.
    func filter(_ samples: [TimedSample]) -> [GazeFeatures] {
        let inWindow = samples.filter {
            $0.elapsed >= collectionStart && $0.elapsed <= collectionEnd && $0.openness >= minOpenness
        }
        guard inWindow.count >= 3 else { return inWindow.map(\.features) }

        let pupils = inWindow.map { Array($0.features.vector.prefix(GazeFeatures.polynomialCount)) }
        let medians = (0..<GazeFeatures.polynomialCount).map { k in Stats.median(pupils.map { $0[k] }) }
        let distances = pupils.map { p in
            zip(p, medians).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
        }
        let limit = max(Stats.median(distances) * outlierFactor, 1e-6)
        return zip(inWindow, distances).filter { $0.1 <= limit }.map { $0.0.features }
    }
}
