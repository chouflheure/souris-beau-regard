import CoreGraphics

/// Position de la tête : milieu des coins des yeux (normalisé dans l'image) et distance entre les yeux
/// (fraction de la largeur de l'image).
struct HeadPose: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var size: Double

    init(x: Double, y: Double, size: Double) {
        self.x = x
        self.y = y
        self.size = size
    }

    init(_ f: GazeFeatures) {
        self.init(x: f.faceCenterX, y: f.faceCenterY, size: f.faceSize)
    }

    /// Médiane d'un ensemble de mesures, ou `nil` s'il est vide.
    static func median(of features: [GazeFeatures]) -> HeadPose? {
        guard !features.isEmpty else { return nil }
        return HeadPose(x: Stats.median(features.map(\.faceCenterX)),
                        y: Stats.median(features.map(\.faceCenterY)),
                        size: Stats.median(features.map(\.faceSize)))
    }
}

/// Détecte un déplacement durable de la tête par rapport à la position de référence (calibration ou
/// dernier recalage), pour proposer de recaler. Logique pure, testée.
struct HeadDriftMonitor: Sendable, Equatable {
    /// Déplacement latéral toléré, en distances entre les yeux (0,5 ≈ 3 cm).
    var lateralThreshold = 0.5
    /// Variation de taille tolérée (0,12 = s'avancer ou reculer d'environ 12 %).
    var sizeThreshold = 0.12
    /// Durée au-delà du seuil avant de proposer (s), et sous 70 % du seuil avant de retirer la proposition.
    var sustain = 1.5
    var clearAfter = 1.0
    /// Hauteur / largeur de l'image (y est normalisé sur la hauteur, la taille sur la largeur).
    var aspect = 9.0 / 16.0

    private(set) var current: HeadPose?
    private(set) var suggestRecenter = false
    private var overSince: Double?
    private var underSince: Double?

    /// Écart à la référence, en multiples du seuil (> 1 : au-delà).
    static func driftScore(_ pose: HeadPose, reference: HeadPose, lateralThreshold: Double,
                           sizeThreshold: Double, aspect: Double) -> Double {
        guard reference.size > 0 else { return 0 }
        let dx = (pose.x - reference.x) / reference.size
        let dy = (pose.y - reference.y) * aspect / reference.size
        let lateral = (dx * dx + dy * dy).squareRoot() / lateralThreshold
        let depth = abs(pose.size - reference.size) / reference.size / sizeThreshold
        return max(lateral, depth)
    }

    var score: Double? {
        guard let current, let reference = lastReference else { return nil }
        return Self.driftScore(current, reference: reference, lateralThreshold: lateralThreshold,
                               sizeThreshold: sizeThreshold, aspect: aspect)
    }
    private var lastReference: HeadPose?

    /// Ajoute une mesure ; renvoie `true` s'il faut proposer de recaler.
    @discardableResult
    mutating func update(_ pose: HeadPose, reference: HeadPose?, time: Double) -> Bool {
        // Lissage (constante de temps ≈ 0,3 s à 30 i/s) : le bruit de mesure ne déclenche rien.
        if let c = current {
            let a = 0.1
            current = HeadPose(x: c.x + a * (pose.x - c.x), y: c.y + a * (pose.y - c.y),
                               size: c.size + a * (pose.size - c.size))
        } else {
            current = pose
        }
        lastReference = reference
        guard let score else { return suggestRecenter }
        if score > 1 {
            underSince = nil
            if overSince == nil { overSince = time }
            if let since = overSince, time - since >= sustain { suggestRecenter = true }
        } else {
            overSince = nil
            if score < 0.7 {
                if underSince == nil { underSince = time }
                if let since = underSince, time - since >= clearAfter { suggestRecenter = false }
            } else {
                underSince = nil
            }
        }
        return suggestRecenter
    }

    /// Après un recalage : la position actuelle devient la référence, plus de proposition.
    mutating func acknowledge() {
        suggestRecenter = false
        overSince = nil
        underSince = nil
    }
}
