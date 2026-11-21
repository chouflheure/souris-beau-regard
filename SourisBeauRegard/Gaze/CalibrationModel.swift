import CoreGraphics
import Foundation

/// Une mesure associée au point regardé (points Quartz).
struct CalibrationSample: Codable, Sendable, Equatable {
    var features: GazeFeatures
    var target: CGPoint
}

/// Erreur de validation, en points écran.
struct ValidationResult: Codable, Sendable, Equatable {
    var meanError: Double
    var maxError: Double
    /// Erreur moyenne sur chaque axe (|Δx|, |Δy|) : dit si c'est l'horizontal ou le vertical qui pèche.
    var meanErrorX: Double
    var meanErrorY: Double
    /// Pour chaque point de validation : erreur, cible et estimation (`nil` si aucune mesure).
    var pointErrors: [Double?]
    var targets: [CGPoint?]
    var estimates: [CGPoint?]
}

/// Modèle de calibration complet, enregistré en JSON.
///
/// Les mesures brutes sont gardées : changer de modèle ou de λ refait l'apprentissage et la
/// validation sans recalibrer.
struct CalibrationModel: Codable, Sendable, Equatable {
    static let currentVersion = 3

    var version = CalibrationModel.currentVersion
    var createdAt: Date
    /// Écran calibré, en points Quartz.
    var screenFrame: CGRect
    /// Méthode de pupille utilisée pendant la calibration.
    var pupilLocator: PupilLocatorKind
    var calibrationSamples: [CalibrationSample]
    /// Mesures de validation, groupées par point.
    var validationSamples: [[CalibrationSample]] = []
    var kind: GazeModelKind
    var regression: RidgeRegression
    /// Erreur sur les points de validation, avec un modèle appris sur les seuls points de calibration
    /// (mesure honnête : ces points n'ont pas servi à apprendre).
    var validation: ValidationResult?
    /// Le modèle final apprend aussi sur les points de validation (plus de points = meilleur modèle).
    var trainedOnValidation = false
    /// Erreur estimée du modèle final par validation croisée (points écran).
    var crossValidationError: Double?
    /// Choix fait automatiquement à la calibration (modèle, λ), s'il y en a eu un.
    var autoKind: GazeModelKind?
    var autoLambda: Double?
    /// Décalage de recentrage ajouté aux prédictions (points écran).
    var offset: CGPoint = .zero

    // Apprentissage continu (optionnels : un fichier plus ancien se lit sans eux).
    /// Mesures apprises des vrais clics de souris (on regarde ce qu'on clique).
    var implicitSamples: [CalibrationSample]?
    /// Derniers événements (clic ou recentrage), qui fixent le décalage.
    var recentEvents: [[CalibrationSample]]?
    /// Clics retenus depuis la calibration.
    var implicitEventCount: Int?

    var lambda: Double { regression.lambda }

    var trainingSamples: [CalibrationSample] {
        (trainedOnValidation ? calibrationSamples + validationSamples.flatMap { $0 } : calibrationSamples)
            + (implicitSamples ?? [])
    }

    enum FitError: LocalizedError, Equatable {
        case notEnoughSamples
        case regression(RidgeRegression.FitError)

        var errorDescription: String? {
            switch self {
            case .notEnoughSamples:
                "Pas assez de mesures valides. Le visage était-il bien visible et éclairé ?"
            case .regression:
                "Le calcul de la calibration a échoué. Recommencez en gardant la tête immobile."
            }
        }
    }

    /// Nombre minimal de mesures et de points distincts pour apprendre.
    static let minimumSamples = 30
    static let minimumDistinctTargets = 6

    /// Apprend sur les points de calibration. `kind` / `lambda` à `nil` : choix automatique.
    static func fit(samples: [CalibrationSample], screenFrame: CGRect,
                    pupilLocator: PupilLocatorKind,
                    kind: GazeModelKind?, lambda: Double?,
                    date: Date = Date()) throws -> CalibrationModel {
        try checkEnough(samples)
        let choice = choose(samples, kind: kind, lambda: lambda)
        let regression = try fitRegression(samples, kind: choice.kind, lambda: choice.lambda)
        var model = CalibrationModel(createdAt: date, screenFrame: screenFrame, pupilLocator: pupilLocator,
                                     calibrationSamples: samples, kind: choice.kind, regression: regression)
        model.crossValidationError = ModelSelection.crossValidationError(samples, kind: choice.kind,
                                                                         lambda: choice.lambda)
        if kind == nil { model.autoKind = choice.kind }
        if lambda == nil { model.autoLambda = choice.lambda }
        return model
    }

    /// Ajoute la validation ; si `trainOnValidation`, réapprend sur tous les points
    /// (en refaisant le choix automatique s'il y en avait un).
    mutating func finalize(validation groups: [[CalibrationSample]], trainOnValidation: Bool) throws {
        validationSamples = groups
        validation = Self.validate(groups, kind: kind, with: regression)
        guard trainOnValidation, groups.contains(where: { !$0.isEmpty }) else { return }
        trainedOnValidation = true
        let all = trainingSamples
        let choice = Self.choose(all, kind: autoKind == nil ? kind : nil,
                                 lambda: autoLambda == nil ? lambda : nil)
        if autoKind != nil { autoKind = choice.kind }
        if autoLambda != nil { autoLambda = choice.lambda }
        try refit(kind: choice.kind, lambda: choice.lambda)
    }

    /// Refait l'apprentissage avec un autre modèle ou λ ; recalcule validation et validation croisée.
    mutating func refit(kind: GazeModelKind, lambda: Double) throws {
        let calibrationOnly = try Self.fitRegression(calibrationSamples, kind: kind, lambda: lambda)
        validation = Self.validate(validationSamples, kind: kind, with: calibrationOnly)
        if trainedOnValidation {
            regression = try Self.fitRegression(trainingSamples, kind: kind, lambda: lambda)
        } else {
            regression = calibrationOnly
        }
        self.kind = kind
        crossValidationError = ModelSelection.crossValidationError(trainingSamples, kind: kind, lambda: lambda)
    }

    private static func choose(_ samples: [CalibrationSample], kind: GazeModelKind?,
                               lambda: Double?) -> ModelSelection.Choice {
        let kinds = kind.map { [$0] } ?? GazeModelKind.allCases
        let lambdas = lambda.map { [$0] } ?? ModelSelection.lambdaGrid
        return ModelSelection.best(samples, kinds: kinds, lambdas: lambdas)
            ?? ModelSelection.Choice(kind: kind ?? .binocular, lambda: lambda ?? 10, error: .infinity)
    }

    private static func checkEnough(_ samples: [CalibrationSample]) throws {
        let distinct = Set(samples.map { "\($0.target.x),\($0.target.y)" })
        guard samples.count >= minimumSamples, distinct.count >= minimumDistinctTargets else {
            throw FitError.notEnoughSamples
        }
    }

    private static func fitRegression(_ samples: [CalibrationSample], kind: GazeModelKind,
                                      lambda: Double) throws -> RidgeRegression {
        try checkEnough(samples)
        do {
            return try kind.fit(samples, lambda: lambda)
        } catch let error as RidgeRegression.FitError {
            throw FitError.regression(error)
        }
    }

    // MARK: - Apprentissage continu

    enum LearnOutcome: Equatable {
        case accepted
        /// Le clic est trop loin du regard estimé : on ne regardait sans doute pas ce qu'on cliquait.
        case rejected
    }

    /// Écart médian (cible − prédiction sans décalage) sur un groupe de mesures.
    func residual(_ group: [CalibrationSample]) -> CGPoint? {
        guard !group.isEmpty else { return nil }
        let r = group.map { s -> CGPoint in
            let p = predictUncorrected(s.features)
            return CGPoint(x: s.target.x - p.x, y: s.target.y - p.y)
        }
        return CGPoint(x: Stats.median(r.map { Double($0.x) }), y: Stats.median(r.map { Double($0.y) }))
    }

    /// Décalage = médiane des écarts des derniers événements.
    mutating func updateOffsetFromEvents() {
        let residuals = (recentEvents ?? []).compactMap { residual($0) }
        guard !residuals.isEmpty else { return }
        offset = CGPoint(x: Stats.median(residuals.map { Double($0.x) }),
                         y: Stats.median(residuals.map { Double($0.y) }))
    }

    /// Apprend d'un clic (ou d'un recentrage) : `features` mesurées juste avant, `target` le point visé.
    /// - Parameters:
    ///   - resetHistory: oublie les événements précédents (recentrage après un déplacement).
    ///   - addToTraining: ajoute les mesures à l'apprentissage du modèle (clics).
    ///   - maxError: au-delà (points, décalage actuel compris), l'événement est rejeté ; `nil` : jamais.
    @discardableResult
    mutating func learn(from features: [GazeFeatures], target: CGPoint, maxError: Double?,
                        resetHistory: Bool = false, addToTraining: Bool = true,
                        eventWindow: Int = 5, maxSamples: Int = 400) -> LearnOutcome {
        let group = features.map { CalibrationSample(features: $0, target: target) }
        guard let r = residual(group) else { return .rejected }
        if let maxError, hypot(r.x - offset.x, r.y - offset.y) > maxError { return .rejected }
        var events = resetHistory ? [] : (recentEvents ?? [])
        events.append(group)
        if events.count > eventWindow { events.removeFirst(events.count - eventWindow) }
        recentEvents = events
        if addToTraining {
            var samples = (implicitSamples ?? []) + group
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            implicitSamples = samples
            implicitEventCount = (implicitEventCount ?? 0) + 1
        }
        updateOffsetFromEvents()
        return .accepted
    }

    /// Réapprend le modèle avec les mesures des clics (même modèle et même λ, sans validation croisée,
    /// trop coûteuse avec des centaines de points), puis recalcule le décalage.
    mutating func refitWithImplicitSamples() throws {
        regression = try Self.fitRegression(trainingSamples, kind: kind, lambda: lambda)
        updateOffsetFromEvents()
    }

    /// Point regardé, sans le décalage de recentrage.
    func predictUncorrected(_ features: GazeFeatures) -> CGPoint {
        kind.predict(features, with: regression)
    }

    /// Point regardé, décalage de recentrage compris.
    func predict(_ features: GazeFeatures) -> CGPoint {
        let p = predictUncorrected(features)
        return CGPoint(x: p.x + offset.x, y: p.y + offset.y)
    }

    /// Pour chaque point : médiane des prédictions, puis distance à la cible.
    static func validate(_ groups: [[CalibrationSample]], kind: GazeModelKind,
                         with regression: RidgeRegression) -> ValidationResult? {
        var errors: [Double?] = [], targets: [CGPoint?] = [], estimates: [CGPoint?] = []
        var dxs: [Double] = [], dys: [Double] = []
        for group in groups {
            guard let target = group.first?.target else {
                errors.append(nil); targets.append(nil); estimates.append(nil)
                continue
            }
            let estimate = ModelSelection.medianPrediction(group, kind: kind, regression: regression)
            let dx = Double(abs(estimate.x - target.x)), dy = Double(abs(estimate.y - target.y))
            errors.append(hypot(dx, dy)); targets.append(target); estimates.append(estimate)
            dxs.append(dx); dys.append(dy)
        }
        let valid = errors.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        let n = Double(valid.count)
        return ValidationResult(meanError: valid.reduce(0, +) / n,
                                maxError: valid.max() ?? 0,
                                meanErrorX: dxs.reduce(0, +) / n,
                                meanErrorY: dys.reduce(0, +) / n,
                                pointErrors: errors, targets: targets, estimates: estimates)
    }
}

/// Petites statistiques robustes.
enum Stats {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Lecture et écriture du modèle en JSON dans Application Support.
struct CalibrationStore: Sendable {
    let url: URL

    init(url: URL = CalibrationStore.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SourisBeauRegard", isDirectory: true)
            .appendingPathComponent("calibration.json")
    }

    /// `nil` si absent, illisible ou d'une version antérieure (mesures différentes : recalibrer).
    func load() -> CalibrationModel? {
        guard let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(CalibrationModel.self, from: data),
              model.version == CalibrationModel.currentVersion
        else { return nil }
        return model
    }

    func save(_ model: CalibrationModel) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(model).write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
