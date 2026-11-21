import CoreGraphics

/// Déroulé de la calibration : positions des points, durées, tri des mesures. Logique pure.
struct CalibrationPlan: Sendable, Equatable {
    /// Taille de la grille de calibration (3 → 9 points, 4 → 16, 5 → 25).
    var gridSize = 3
    /// Positions de tête supplémentaires (0…4), chacune avec une grille 3×3 : le modèle apprend
    /// ainsi à corriger les déplacements de la tête au lieu de les prendre pour un regard ailleurs.
    var extraPoses = 0

    /// Consignes des positions supplémentaires, dans l'ordre.
    static let poseInstructions = [
        "Décalez-vous d'environ 10 cm vers la gauche, en gardant le visage face à l'écran.",
        "Décalez-vous d'environ 10 cm vers la droite.",
        "Reculez d'environ 10 cm.",
        "Approchez-vous d'environ 10 cm.",
    ]

    var poses: [String] { Array(Self.poseInstructions.prefix(min(max(extraPoses, 0), Self.poseInstructions.count))) }
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

    /// Grille n×n régulière entre les marges de 8 %, en coordonnées normalisées (0…1, origine haut-gauche).
    static func grid(size: Int) -> [CGPoint] {
        let n = max(size, 2)
        let values: [CGFloat] = (0..<n).map { i in
            i == n - 1 ? 1 - margin : margin + (1 - 2 * margin) * CGFloat(i) / CGFloat(n - 1)
        }
        return values.flatMap { y in values.map { x in CGPoint(x: x, y: y) } }
    }

    /// Grille 3×3 du cahier des charges.
    static var calibrationGrid: [CGPoint] { grid(size: 3) }

    /// 5 points de validation : centre et quatre points intermédiaires (différents de la grille).
    static let validationPoints: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.27, y: 0.28),
        CGPoint(x: 0.73, y: 0.28),
        CGPoint(x: 0.27, y: 0.72),
        CGPoint(x: 0.73, y: 0.72),
    ]

    func calibrationPoints<G: RandomNumberGenerator>(using generator: inout G) -> [CGPoint] {
        Self.grid(size: gridSize).shuffled(using: &generator)
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

        let pupils = inWindow.map { Array($0.features.vector.prefix(GazeFeatures.pupilCount)) }
        let medians = (0..<GazeFeatures.pupilCount).map { k in Stats.median(pupils.map { $0[k] }) }
        let distances = pupils.map { p in
            zip(p, medians).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
        }
        let limit = max(Stats.median(distances) * outlierFactor, 1e-6)
        return zip(inWindow, distances).filter { $0.1 <= limit }.map { $0.0.features }
    }
}
