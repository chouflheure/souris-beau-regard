import CoreGraphics

/// Variantes du modèle de régression, de la plus simple à la plus riche.
///
/// Avec 9 points de calibration, le modèle complet du cahier des charges (4 pupilles en degré 2
/// + tête : 21 coefficients par axe) a plus de paramètres que de points : il apprend le bruit.
/// Les variantes « binoculaires » moyennent les deux yeux (moins de bruit, 6 ou 12 coefficients).
enum GazeModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Moyenne des deux pupilles (x, y) en degré 2, plus l'ouverture des yeux.
    case binocular
    /// Idem, plus les 6 mesures de la tête en linéaire.
    case binocularHead
    /// Cahier des charges : 4 pupilles en degré 2, ouverture et tête en linéaire.
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .binocular: "Deux yeux moyennés"
        case .binocularHead: "Deux yeux moyennés + tête"
        case .full: "Complet (4 pupilles + tête)"
        }
    }

    /// Nombre de valeurs en tête de `inputs` traitées en polynôme de degré 2.
    var polynomialCount: Int { self == .full ? 4 : 2 }

    func inputs(_ f: GazeFeatures) -> [Double] {
        let mx = (f.leftPupilX + f.rightPupilX) / 2
        let my = (f.leftPupilY + f.rightPupilY) / 2
        switch self {
        case .binocular:
            return [mx, my, f.aperture]
        case .binocularHead:
            return [mx, my, f.aperture] + f.headVector
        case .full:
            return [f.leftPupilX, f.leftPupilY, f.rightPupilX, f.rightPupilY, f.aperture] + f.headVector
        }
    }

    func fit(_ samples: [CalibrationSample], lambda: Double) throws -> RidgeRegression {
        try RidgeRegression.fit(inputs: samples.map { inputs($0.features) },
                                targets: samples.map(\.target),
                                lambda: lambda,
                                polynomialCount: polynomialCount)
    }

    func predict(_ f: GazeFeatures, with regression: RidgeRegression) -> CGPoint {
        regression.predict(inputs(f))
    }
}

/// Choix du modèle et de λ par validation croisée « un point laissé de côté » :
/// pour chaque point de calibration, on apprend sur les autres et on mesure l'erreur sur celui-là.
/// Logique pure, testée.
enum ModelSelection {
    static let lambdaGrid: [Double] = [0.03, 0.1, 0.3, 1, 3, 10, 30, 100, 300, 1000]

    struct Choice: Sendable, Equatable {
        var kind: GazeModelKind
        var lambda: Double
        /// Erreur moyenne de validation croisée, en points écran.
        var error: Double
    }

    /// Regroupe les mesures par point regardé, dans l'ordre d'apparition.
    static func groups(_ samples: [CalibrationSample]) -> [[CalibrationSample]] {
        var order: [String] = []
        var byKey: [String: [CalibrationSample]] = [:]
        for s in samples {
            let key = "\(s.target.x),\(s.target.y)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(s)
        }
        return order.compactMap { byKey[$0] }
    }

    /// Médiane des prédictions d'un groupe de mesures.
    static func medianPrediction(_ group: [CalibrationSample], kind: GazeModelKind,
                                 regression: RidgeRegression) -> CGPoint {
        let predictions = group.map { kind.predict($0.features, with: regression) }
        return CGPoint(x: Stats.median(predictions.map { Double($0.x) }),
                       y: Stats.median(predictions.map { Double($0.y) }))
    }

    /// Nombre maximal de plis : au-delà de ce nombre de points, on les répartit en plis.
    static let maxFolds = 12

    /// Erreur moyenne (points) en laissant chaque point de côté ; `nil` si impossible.
    /// Avec beaucoup de points (grande grille, positions de tête, clics), les points sont répartis
    /// en `maxFolds` plis pour garder un calcul rapide.
    static func crossValidationError(_ samples: [CalibrationSample], kind: GazeModelKind,
                                     lambda: Double) -> Double? {
        let groups = groups(samples)
        guard groups.count >= 3 else { return nil }
        let foldCount = min(groups.count, maxFolds)
        var errors: [Double] = []
        for fold in 0..<foldCount {
            let held = groups.indices.filter { $0 % foldCount == fold }
            let training = groups.indices.filter { $0 % foldCount != fold }.flatMap { groups[$0] }
            guard let regression = try? kind.fit(training, lambda: lambda) else { return nil }
            for i in held {
                guard let target = groups[i].first?.target else { continue }
                let estimate = medianPrediction(groups[i], kind: kind, regression: regression)
                errors.append(Double(hypot(estimate.x - target.x, estimate.y - target.y)))
            }
        }
        guard errors.count == groups.count else { return nil }
        return errors.reduce(0, +) / Double(errors.count)
    }

    /// Meilleure combinaison parmi `kinds` × `lambdas`.
    static func best(_ samples: [CalibrationSample],
                     kinds: [GazeModelKind] = GazeModelKind.allCases,
                     lambdas: [Double] = lambdaGrid) -> Choice? {
        var best: Choice?
        for kind in kinds {
            for lambda in lambdas {
                guard let error = crossValidationError(samples, kind: kind, lambda: lambda) else { continue }
                if best == nil || error < best!.error {
                    best = Choice(kind: kind, lambda: lambda, error: error)
                }
            }
        }
        return best
    }
}
