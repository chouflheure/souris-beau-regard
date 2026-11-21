import Foundation
import Observation

/// Réglages persistants (UserDefaults). Une valeur incertaine devient un réglage
/// plutôt qu'une constante devinée. La fenêtre de réglages complète arrive à l'étape 5.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let mirrorPreview = "debug.mirrorPreview"
        static let minFaceConfidence = "quality.minFaceConfidence"
        static let minEyeOpenness = "quality.minEyeOpenness"
        static let minFPS = "quality.minFPS"
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
        ])
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        mirrorPreview = defaults.bool(forKey: Key.mirrorPreview)
        minFaceConfidence = defaults.double(forKey: Key.minFaceConfidence)
        minEyeOpenness = defaults.double(forKey: Key.minEyeOpenness)
        minFPS = defaults.double(forKey: Key.minFPS)
    }
}
