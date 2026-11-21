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
    /// Erreur de chaque point de validation (`nil` si aucune mesure pour ce point).
    var pointErrors: [Double?]
}

/// Modèle de calibration complet, enregistré en JSON.
///
/// Les mesures brutes sont gardées : changer λ refait l'apprentissage et la validation sans
/// recalibrer.
struct CalibrationModel: Codable, Sendable, Equatable {
    var version = 1
    var createdAt: Date
    /// Écran calibré, en points Quartz.
    var screenFrame: CGRect
    /// Méthode de pupille utilisée pendant la calibration.
    var pupilLocator: PupilLocatorKind
    var calibrationSamples: [CalibrationSample]
    /// Mesures de validation, groupées par point.
    var validationSamples: [[CalibrationSample]]
    var regression: RidgeRegression
    var validation: ValidationResult?
    /// Décalage de recentrage ajouté aux prédictions (points écran).
    var offset: CGPoint = .zero

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

    static func fit(samples: [CalibrationSample], screenFrame: CGRect,
                    pupilLocator: PupilLocatorKind, lambda: Double,
                    date: Date = Date()) throws -> CalibrationModel {
        let regression = try fitRegression(samples, lambda: lambda)
        return CalibrationModel(createdAt: date, screenFrame: screenFrame, pupilLocator: pupilLocator,
                                calibrationSamples: samples, validationSamples: [],
                                regression: regression, validation: nil)
    }

    private static func fitRegression(_ samples: [CalibrationSample], lambda: Double) throws -> RidgeRegression {
        let distinct = Set(samples.map { "\($0.target.x),\($0.target.y)" })
        guard samples.count >= minimumSamples, distinct.count >= minimumDistinctTargets else {
            throw FitError.notEnoughSamples
        }
        do {
            return try RidgeRegression.fit(inputs: samples.map(\.features.vector),
                                           targets: samples.map(\.target),
                                           lambda: lambda,
                                           polynomialCount: GazeFeatures.polynomialCount)
        } catch let error as RidgeRegression.FitError {
            throw FitError.regression(error)
        }
    }

    /// Point regardé, sans le décalage de recentrage.
    func predictUncorrected(_ features: GazeFeatures) -> CGPoint {
        regression.predict(features.vector)
    }

    /// Point regardé, décalage de recentrage compris.
    func predict(_ features: GazeFeatures) -> CGPoint {
        let p = predictUncorrected(features)
        return CGPoint(x: p.x + offset.x, y: p.y + offset.y)
    }

    mutating func setValidation(_ groups: [[CalibrationSample]]) {
        validationSamples = groups
        validation = Self.validate(groups, with: regression)
    }

    /// Refait l'apprentissage avec un autre λ et recalcule l'erreur de validation.
    mutating func refit(lambda: Double) throws {
        regression = try Self.fitRegression(calibrationSamples, lambda: lambda)
        validation = Self.validate(validationSamples, with: regression)
    }

    /// Pour chaque point : médiane des prédictions, puis distance à la cible.
    static func validate(_ groups: [[CalibrationSample]], with regression: RidgeRegression) -> ValidationResult? {
        let errors: [Double?] = groups.map { group in
            guard let target = group.first?.target else { return nil }
            let predictions = group.map { regression.predict($0.features.vector) }
            let estimate = CGPoint(x: Stats.median(predictions.map { Double($0.x) }),
                                   y: Stats.median(predictions.map { Double($0.y) }))
            return Double(hypot(estimate.x - target.x, estimate.y - target.y))
        }
        let valid = errors.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        return ValidationResult(meanError: valid.reduce(0, +) / Double(valid.count),
                                maxError: valid.max() ?? 0,
                                pointErrors: errors)
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

    func load() -> CalibrationModel? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CalibrationModel.self, from: data)
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
