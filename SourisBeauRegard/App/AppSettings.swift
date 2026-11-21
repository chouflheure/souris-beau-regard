import Foundation
import Observation

/// Réglages persistants (UserDefaults). Une valeur incertaine devient un réglage
/// plutôt qu'une constante devinée. La fenêtre de réglages complète arrive à l'étape 5.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Prévient l'état central quand l'affichage ou le suivi du regard change.
    @ObservationIgnored var onGazeDisplayChange: (@MainActor () -> Void)?

    private enum Key {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let mirrorPreview = "debug.mirrorPreview"
        static let minFaceConfidence = "quality.minFaceConfidence"
        static let minEyeOpenness = "quality.minEyeOpenness"
        static let minFPS = "quality.minFPS"
        static let pupilLocator = "gaze.pupilLocator"
        static let pupilDarkFraction = "gaze.pupilDarkFraction"
        static let ridgeLambda = "gaze.ridgeLambda"
        static let lambdaAuto = "gaze.lambdaAuto"
        static let modelChoice = "gaze.modelChoice"
        static let calibrationGridSize = "calibration.gridSize"
        static let trainOnValidation = "calibration.trainOnValidation"
        static let trackingEnabled = "gaze.trackingEnabled"
        static let showGazePoint = "overlay.showGazePoint"
        // Clés « v2 » : les valeurs par défaut ont changé, les anciennes valeurs enregistrées sont ignorées.
        static let smoothingMinCutoff = "gaze.smoothing.v2.minCutoff"
        static let smoothingBeta = "gaze.smoothing.v2.beta"
        static let medianWindow = "gaze.smoothing.v2.medianWindow"
        static let fixationDuration = "gaze.fixation.v2.duration"
        static let fixationDispersion = "gaze.fixation.v2.dispersion"
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }
    /// Aperçu de débogage affiché en miroir (plus naturel pour se voir).
    var mirrorPreview: Bool {
        didSet { defaults.set(mirrorPreview, forKey: Key.mirrorPreview) }
    }
    /// En dessous, avertissement « confiance faible ».
    var minFaceConfidence: Double {
        didSet { defaults.set(minFaceConfidence, forKey: Key.minFaceConfidence) }
    }
    /// Ouverture (hauteur / largeur) en dessous de laquelle l'œil est considéré fermé ou mal vu.
    var minEyeOpenness: Double {
        didSet { defaults.set(minEyeOpenness, forKey: Key.minEyeOpenness) }
    }
    /// Images par seconde minimales attendues.
    var minFPS: Double {
        didSet { defaults.set(minFPS, forKey: Key.minFPS) }
    }

    /// Méthode de localisation de la pupille utilisée pour le regard.
    var pupilLocator: PupilLocatorKind {
        didSet { defaults.set(pupilLocator.rawValue, forKey: Key.pupilLocator) }
    }
    /// Part des pixels de l'œil retenus comme pupille par `ImagePupilLocator`.
    var pupilDarkFraction: Double {
        didSet { defaults.set(pupilDarkFraction, forKey: Key.pupilDarkFraction) }
    }
    /// Force de la régularisation ridge (λ).
    var ridgeLambda: Double {
        didSet { defaults.set(ridgeLambda, forKey: Key.ridgeLambda) }
    }
    /// λ choisi automatiquement par validation croisée à la calibration.
    var lambdaAuto: Bool {
        didSet { defaults.set(lambdaAuto, forKey: Key.lambdaAuto) }
    }
    /// Modèle imposé, ou `nil` pour un choix automatique par validation croisée.
    var modelChoice: GazeModelKind? {
        didSet { defaults.set(modelChoice?.rawValue ?? "auto", forKey: Key.modelChoice) }
    }
    /// Grille de calibration n×n (3 = 9 points, 4 = 16, 5 = 25).
    var calibrationGridSize: Int {
        didSet { defaults.set(calibrationGridSize, forKey: Key.calibrationGridSize) }
    }
    /// Le modèle final apprend aussi sur les 5 points de validation.
    var trainOnValidation: Bool {
        didSet { defaults.set(trainOnValidation, forKey: Key.trainOnValidation) }
    }
    /// Suivi du regard actif (si une calibration existe).
    var trackingEnabled: Bool {
        didSet {
            defaults.set(trackingEnabled, forKey: Key.trackingEnabled)
            onGazeDisplayChange?()
        }
    }
    /// Point de regard dessiné par-dessus tout.
    var showGazePoint: Bool {
        didSet {
            defaults.set(showGazePoint, forKey: Key.showGazePoint)
            onGazeDisplayChange?()
        }
    }
    /// Filtre One Euro : coupure minimale (Hz).
    var smoothingMinCutoff: Double {
        didSet { defaults.set(smoothingMinCutoff, forKey: Key.smoothingMinCutoff) }
    }
    /// Filtre One Euro : gain de vitesse.
    var smoothingBeta: Double {
        didSet { defaults.set(smoothingBeta, forKey: Key.smoothingBeta) }
    }
    /// Fixation : durée minimale (s).
    var fixationDuration: Double {
        didSet { defaults.set(fixationDuration, forKey: Key.fixationDuration) }
    }
    /// Fixation : dispersion maximale (points écran).
    var fixationDispersion: Double {
        didSet { defaults.set(fixationDispersion, forKey: Key.fixationDispersion) }
    }
    /// Filtre médian avant le lissage, en images (1 = désactivé).
    var medianWindow: Int {
        didSet { defaults.set(medianWindow, forKey: Key.medianWindow) }
    }

    /// Remet le lissage et la fixation aux valeurs par défaut.
    func resetSmoothing() {
        let d = GazeParameters()
        smoothingMinCutoff = d.minCutoff
        smoothingBeta = d.beta
        fixationDuration = d.fixationDuration
        fixationDispersion = d.fixationDispersion
        medianWindow = d.medianWindow
    }

    /// λ en échelle logarithmique, pour un curseur.
    var ridgeLambdaLog10: Double {
        get { log10(ridgeLambda) }
        set { ridgeLambda = pow(10, newValue) }
    }

    var gazeParameters: GazeParameters {
        GazeParameters(minCutoff: smoothingMinCutoff, beta: smoothingBeta, derivativeCutoff: 1.0,
                       fixationDuration: fixationDuration, fixationDispersion: fixationDispersion,
                       medianWindow: medianWindow)
    }

    var calibrationPlan: CalibrationPlan {
        var plan = CalibrationPlan()
        plan.minOpenness = minEyeOpenness
        plan.gridSize = calibrationGridSize
        return plan
    }

    var qualityThresholds: FaceQuality.Thresholds {
        FaceQuality.Thresholds(minFaceConfidence: minFaceConfidence,
                               minEyeOpenness: minEyeOpenness,
                               minFPS: minFPS)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hasCompletedOnboarding: false,
            Key.mirrorPreview: true,
            Key.minFaceConfidence: 0.5,
            Key.minEyeOpenness: 0.15,
            Key.minFPS: 25.0,
            Key.pupilLocator: PupilLocatorKind.image.rawValue,
            Key.pupilDarkFraction: 0.12,
            Key.ridgeLambda: 10.0,
            Key.lambdaAuto: true,
            Key.modelChoice: "auto",
            Key.calibrationGridSize: 3,
            Key.trainOnValidation: true,
            Key.trackingEnabled: true,
            Key.showGazePoint: true,
            Key.smoothingMinCutoff: GazeParameters().minCutoff,
            Key.smoothingBeta: GazeParameters().beta,
            Key.fixationDuration: GazeParameters().fixationDuration,
            Key.fixationDispersion: GazeParameters().fixationDispersion,
            Key.medianWindow: GazeParameters().medianWindow,
        ])
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        mirrorPreview = defaults.bool(forKey: Key.mirrorPreview)
        minFaceConfidence = defaults.double(forKey: Key.minFaceConfidence)
        minEyeOpenness = defaults.double(forKey: Key.minEyeOpenness)
        minFPS = defaults.double(forKey: Key.minFPS)
        pupilLocator = PupilLocatorKind(rawValue: defaults.string(forKey: Key.pupilLocator) ?? "") ?? .image
        pupilDarkFraction = defaults.double(forKey: Key.pupilDarkFraction)
        ridgeLambda = defaults.double(forKey: Key.ridgeLambda)
        lambdaAuto = defaults.bool(forKey: Key.lambdaAuto)
        modelChoice = GazeModelKind(rawValue: defaults.string(forKey: Key.modelChoice) ?? "auto")
        calibrationGridSize = min(max(defaults.integer(forKey: Key.calibrationGridSize), 3), 5)
        trainOnValidation = defaults.bool(forKey: Key.trainOnValidation)
        trackingEnabled = defaults.bool(forKey: Key.trackingEnabled)
        showGazePoint = defaults.bool(forKey: Key.showGazePoint)
        smoothingMinCutoff = defaults.double(forKey: Key.smoothingMinCutoff)
        smoothingBeta = defaults.double(forKey: Key.smoothingBeta)
        fixationDuration = defaults.double(forKey: Key.fixationDuration)
        fixationDispersion = defaults.double(forKey: Key.fixationDispersion)
        medianWindow = min(max(defaults.integer(forKey: Key.medianWindow), 1), 15)
    }
}
