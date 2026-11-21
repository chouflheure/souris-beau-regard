import Foundation
import Observation

/// Déroulé d'une calibration : 9 points, apprentissage, 5 points de validation, résultat.
/// Reçoit les mesures de chaque image via `ingest`. Sur le fil principal.
@MainActor
@Observable
final class CalibrationSession {
    enum Stage: Equatable {
        case intro
        case calibrating
        case fitting
        case validating
        case result(ValidationResult?)
        case failed(String)
    }

    private(set) var stage: Stage = .intro
    /// Point affiché, normalisé (0…1, origine haut-gauche de l'écran calibré).
    private(set) var currentPoint: CGPoint?
    /// Instant d'apparition du point (`ProcessInfo.systemUptime`).
    private(set) var pointStart: Double = 0
    private(set) var pointIndex = 0
    private(set) var pointCount = 0
    /// Mesures valides reçues pour le point en cours (affichage).
    private(set) var currentSampleCount = 0
    private(set) var model: CalibrationModel?

    let screenFrame: CGRect
    let plan: CalibrationPlan
    let pupilLocator: PupilLocatorKind
    let lambda: Double

    /// Appelé à la fin : le modèle si l'utilisateur valide, `nil` s'il annule.
    @ObservationIgnored var onFinish: (@MainActor (CalibrationModel?) -> Void)?
    @ObservationIgnored private var samples: [CalibrationPlan.TimedSample] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(screenFrame: CGRect, plan: CalibrationPlan, pupilLocator: PupilLocatorKind, lambda: Double) {
        self.screenFrame = screenFrame
        self.plan = plan
        self.pupilLocator = pupilLocator
        self.lambda = lambda
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    var isCollecting: Bool { stage == .calibrating || stage == .validating }

    // MARK: - Commandes

    func begin() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func restart() {
        task?.cancel()
        task = nil
        model = nil
        currentPoint = nil
        stage = .intro
        begin()
    }

    func cancel() {
        task?.cancel()
        task = nil
        onFinish?(nil)
    }

    func accept() {
        guard case .result = stage, let model else { return }
        onFinish?(model)
    }

    /// Mesures d'une image. `features` est `nil` si le visage ou une pupille manque.
    func ingest(features: GazeFeatures?, openness: Double) {
        guard isCollecting, let features else { return }
        let elapsed = Self.now - pointStart
        samples.append(.init(elapsed: elapsed, features: features, openness: openness))
        if elapsed >= plan.collectionStart, openness >= plan.minOpenness {
            currentSampleCount += 1
        }
    }

    // MARK: - Déroulé

    private func run() async {
        var generator = SystemRandomNumberGenerator()
        let points = CalibrationPlan.calibrationPoints(using: &generator)

        stage = .calibrating
        var calibration: [CalibrationSample] = []
        for (i, p) in points.enumerated() {
            guard let kept = await collect(at: p, index: i, count: points.count) else { return }
            let target = CoordinateSpaces.normalizedToQuartz(p, screenFrameQuartz: screenFrame)
            calibration += kept.map { CalibrationSample(features: $0, target: target) }
        }

        stage = .fitting
        currentPoint = nil
        var fitted: CalibrationModel
        do {
            fitted = try CalibrationModel.fit(samples: calibration, screenFrame: screenFrame,
                                              pupilLocator: pupilLocator, lambda: lambda)
        } catch {
            stage = .failed(error.localizedDescription)
            task = nil
            return
        }

        stage = .validating
        var groups: [[CalibrationSample]] = []
        let validation = CalibrationPlan.validationPoints
        for (i, p) in validation.enumerated() {
            guard let kept = await collect(at: p, index: i, count: validation.count) else { return }
            let target = CoordinateSpaces.normalizedToQuartz(p, screenFrameQuartz: screenFrame)
            groups.append(kept.map { CalibrationSample(features: $0, target: target) })
        }
        fitted.setValidation(groups)

        currentPoint = nil
        model = fitted
        stage = .result(fitted.validation)
        task = nil
    }

    /// Affiche un point pendant `pointDuration` et renvoie les mesures gardées (`nil` si annulé).
    private func collect(at point: CGPoint, index: Int, count: Int) async -> [GazeFeatures]? {
        samples = []
        currentSampleCount = 0
        pointIndex = index
        pointCount = count
        currentPoint = point
        pointStart = Self.now
        do {
            try await Task.sleep(for: .seconds(plan.pointDuration))
        } catch {
            return nil
        }
        if Task.isCancelled { return nil }
        return plan.filter(samples)
    }
}
