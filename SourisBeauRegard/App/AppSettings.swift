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
        static let trackingEnabled = "gaze.trackingEnabled"
        static let showGazePoint = "overlay.showGazePoint"
        static let smoothingMinCutoff = "gaze.smoothing.minCutoff"
        static let smoothingBeta = "gaze.smoothing.beta"
        static let fixationDuration = "gaze.fixation.duration"
        static let fixationDispersion = "gaze.fixation.dispersion"
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

    /// λ en échelle logarithmique, pour un curseur.
    var ridgeLambdaLog10: Double {
        get { log10(ridgeLambda) }
        set { ridgeLambda = pow(10, newValue) }
    }

    var gazeParameters: GazeParameters {
        GazeParameters(minCutoff: smoothingMinCutoff, beta: smoothingBeta, derivativeCutoff: 1.0,
                       fixationDuration: fixationDuration, fixationDispersion: fixationDispersion)
    }

    var calibrationPlan: CalibrationPlan {
        var plan = CalibrationPlan()
        plan.minOpenness = minEyeOpenness
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
            Key.ridgeLambda: 5.0,
            Key.trackingEnabled: true,
            Key.showGazePoint: true,
            Key.smoothingMinCutoff: 0.8,
            Key.smoothingBeta: 0.006,
            Key.fixationDuration: 0.15,
            Key.fixationDispersion: 80.0,
        ])
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        mirrorPreview = defaults.bool(forKey: Key.mirrorPreview)
        minFaceConfidence = defaults.double(forKey: Key.minFaceConfidence)
        minEyeOpenness = defaults.double(forKey: Key.minEyeOpenness)
        minFPS = defaults.double(forKey: Key.minFPS)
        pupilLocator = PupilLocatorKind(rawValue: defaults.string(forKey: Key.pupilLocator) ?? "") ?? .image
        pupilDarkFraction = defaults.double(forKey: Key.pupilDarkFraction)
        ridgeLambda = defaults.double(forKey: Key.ridgeLambda)
        trackingEnabled = defaults.bool(forKey: Key.trackingEnabled)
        showGazePoint = defaults.bool(forKey: Key.showGazePoint)
        smoothingMinCutoff = defaults.double(forKey: Key.smoothingMinCutoff)
        smoothingBeta = defaults.double(forKey: Key.smoothingBeta)
        fixationDuration = defaults.double(forKey: Key.fixationDuration)
        fixationDispersion = defaults.double(forKey: Key.fixationDispersion)
    }
}
