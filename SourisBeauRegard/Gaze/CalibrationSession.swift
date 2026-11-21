import Foundation
import Observation

/// Déroulé d'une calibration : 9 points, apprentissage, 5 points de validation, résultat.
/// Reçoit les mesures de chaque image via `ingest`. Sur le fil principal.
@MainActor
@Observable
final class CalibrationSession {
    enum Stage: Equatable {
        case intro
        /// Consigne de changement de position ; Espace pour continuer.
        case poseIntro(String)
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
    /// Modèle et λ imposés, ou `nil` pour un choix automatique par validation croisée.
    let kind: GazeModelKind?
    let lambda: Double?
    /// Le modèle final apprend aussi sur les points de validation.
    let trainOnValidation: Bool

    /// Appelé à la fin : le modèle si l'utilisateur valide, `nil` s'il annule.
    @ObservationIgnored var onFinish: (@MainActor (CalibrationModel?) -> Void)?
    @ObservationIgnored private var samples: [CalibrationPlan.TimedSample] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var poseContinuation: CheckedContinuation<Bool, Never>?
    /// Libellé de la position en cours (« position habituelle », « position 2/5 »…).
    private(set) var poseLabel = ""

    init(screenFrame: CGRect, plan: CalibrationPlan, pupilLocator: PupilLocatorKind,
         kind: GazeModelKind?, lambda: Double?, trainOnValidation: Bool) {
        self.screenFrame = screenFrame
        self.plan = plan
        self.pupilLocator = pupilLocator
        self.kind = kind
        self.lambda = lambda
        self.trainOnValidation = trainOnValidation
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    var isCollecting: Bool { stage == .calibrating || stage == .validating }

    // MARK: - Commandes

    func begin() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func restart() {
        resumePose(false)
        task?.cancel()
        task = nil
        model = nil
        currentPoint = nil
        stage = .intro
        begin()
    }

    func cancel() {
        resumePose(false)
        task?.cancel()
        task = nil
        onFinish?(nil)
    }

    /// Espace pendant une consigne de position.
    func proceed() {
        resumePose(true)
    }

    private func resumePose(_ value: Bool) {
        poseContinuation?.resume(returning: value)
        poseContinuation = nil
    }

    /// Affiche une consigne et attend Espace ; `false` si annulé.
    private func waitForPose(_ text: String) async -> Bool {
        currentPoint = nil
        stage = .poseIntro(text)
        return await withCheckedContinuation { poseContinuation = $0 }
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
        let points = plan.calibrationPoints(using: &generator)

        let poses = plan.poses
        let poseCount = poses.count + 1
        stage = .calibrating
        poseLabel = poseCount > 1 ? "Position habituelle (1/\(poseCount))" : ""
        var calibration: [CalibrationSample] = []
        for (i, p) in points.enumerated() {
            guard let kept = await collect(at: p, index: i, count: points.count) else { return }
            let target = CoordinateSpaces.normalizedToQuartz(p, screenFrameQuartz: screenFrame)
            calibration += kept.map { CalibrationSample(features: $0, target: target) }
        }

        // Positions de tête supplémentaires, grille 3×3 chacune.
        for (k, instruction) in poses.enumerated() {
            guard await waitForPose(instruction) else { return }
            stage = .calibrating
            poseLabel = "Position \(k + 2)/\(poseCount)"
            let posePoints = CalibrationPlan.grid(size: 3).shuffled(using: &generator)
            for (i, p) in posePoints.enumerated() {
                guard let kept = await collect(at: p, index: i, count: posePoints.count) else { return }
                let target = CoordinateSpaces.normalizedToQuartz(p, screenFrameQuartz: screenFrame)
                calibration += kept.map { CalibrationSample(features: $0, target: target) }
            }
        }
        if !poses.isEmpty {
            guard await waitForPose("Revenez à votre position habituelle pour la vérification.") else { return }
        }
        poseLabel = ""

        stage = .fitting
        currentPoint = nil
        var fitted: CalibrationModel
        do {
            fitted = try CalibrationModel.fit(samples: calibration, screenFrame: screenFrame,
                                              pupilLocator: pupilLocator, kind: kind, lambda: lambda)
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
        stage = .fitting
        currentPoint = nil
        do {
            try fitted.finalize(validation: groups, trainOnValidation: trainOnValidation)
        } catch {
            stage = .failed(error.localizedDescription)
            task = nil
            return
        }

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
