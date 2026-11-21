import CoreGraphics

/// Vecteur de mesures d'une image, entrée de la calibration.
/// Les 4 premières valeurs (pupilles) passent par un polynôme de degré 2,
/// les 6 suivantes (tête) restent linéaires.
struct GazeFeatures: Codable, Sendable, Equatable {
    /// Position de la pupille dans la boîte de l'œil, 0…1 (origine bas-gauche comme Vision).
    var leftPupilX: Double
    var leftPupilY: Double
    var rightPupilX: Double
    var rightPupilY: Double
    /// Angles de la tête, radians.
    var yaw: Double
    var pitch: Double
    var roll: Double
    /// Centre et taille (largeur) du visage, normalisés dans l'image.
    var faceCenterX: Double
    var faceCenterY: Double
    var faceSize: Double

    /// Nombre de valeurs en tête de `vector` traitées en polynôme de degré 2.
    static let polynomialCount = 4
    static let count = 10

    var vector: [Double] {
        [leftPupilX, leftPupilY, rightPupilX, rightPupilY,
         yaw, pitch, roll, faceCenterX, faceCenterY, faceSize]
    }

    /// Position d'un point dans une boîte, 0…1. Centre si la boîte est vide.
    static func relative(_ point: CGPoint, in box: CGRect) -> CGPoint {
        guard box.width > 0, box.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - box.minX) / box.width,
                       y: (point.y - box.minY) / box.height)
    }

    /// Mesures d'un visage avec la méthode de pupille choisie ; `nil` s'il manque un œil ou une pupille.
    static func make(from face: FaceMeasurement, locator: PupilLocatorKind) -> GazeFeatures? {
        guard let left = face.leftEye, let right = face.rightEye,
              let lp = left.pupil(locator), let rp = right.pupil(locator)
        else { return nil }
        let l = relative(lp, in: left.box)
        let r = relative(rp, in: right.box)
        return GazeFeatures(
            leftPupilX: Double(l.x), leftPupilY: Double(l.y),
            rightPupilX: Double(r.x), rightPupilY: Double(r.y),
            yaw: face.yaw, pitch: face.pitch, roll: face.roll,
            faceCenterX: Double(face.boundingBox.midX),
            faceCenterY: Double(face.boundingBox.midY),
            faceSize: Double(face.boundingBox.width))
    }
}
