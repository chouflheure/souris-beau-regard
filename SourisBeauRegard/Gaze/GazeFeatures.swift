import CoreGraphics

/// Vecteur de mesures d'une image, entrée de la calibration.
///
/// La pupille est repérée par rapport aux **coins de l'œil** (les deux points du contour les plus
/// éloignés), en pixels : x le long de l'axe coin–coin (0 → 1), y perpendiculaire, divisé par la
/// largeur de l'œil (positif vers le haut). Contrairement à la boîte de l'œil, les coins bougent peu
/// quand la paupière suit le regard vers le bas : le signal vertical n'est pas écrasé.
struct GazeFeatures: Codable, Sendable, Equatable {
    var leftPupilX: Double
    var leftPupilY: Double
    var rightPupilX: Double
    var rightPupilY: Double
    /// Ouverture moyenne des yeux (hauteur du contour / largeur coin–coin) : la paupière supérieure
    /// suit le regard vertical, c'est donc aussi un signal.
    var aperture: Double
    /// Angles de la tête, radians.
    var yaw: Double
    var pitch: Double
    var roll: Double
    /// Centre et taille (largeur) du visage, normalisés dans l'image.
    var faceCenterX: Double
    var faceCenterY: Double
    var faceSize: Double

    /// Les 4 premières valeurs de `vector` sont les pupilles.
    static let pupilCount = 4
    static let count = 11

    var vector: [Double] {
        [leftPupilX, leftPupilY, rightPupilX, rightPupilY, aperture,
         yaw, pitch, roll, faceCenterX, faceCenterY, faceSize]
    }

    var headVector: [Double] { [yaw, pitch, roll, faceCenterX, faceCenterY, faceSize] }

    // MARK: - Repère de l'œil

    /// Les deux points les plus éloignés du contour (coins de l'œil), le plus à gauche en premier.
    static func corners(of contour: [CGPoint]) -> (CGPoint, CGPoint)? {
        guard contour.count >= 2 else { return nil }
        var best: (CGPoint, CGPoint)?
        var bestDistance: CGFloat = 0
        for i in 0..<contour.count {
            for j in (i + 1)..<contour.count {
                let d = hypot(contour[i].x - contour[j].x, contour[i].y - contour[j].y)
                if d > bestDistance { bestDistance = d; best = (contour[i], contour[j]) }
            }
        }
        guard let pair = best, bestDistance > 0 else { return nil }
        return pair.0.x <= pair.1.x ? pair : (pair.1, pair.0)
    }

    /// Position de `p` dans le repère coin `a` → coin `b` (coordonnées isotropes, y vers le haut) :
    /// x le long de l'axe (0 en `a`, 1 en `b`), y perpendiculaire en largeurs d'œil.
    static func position(of p: CGPoint, cornerA a: CGPoint, cornerB b: CGPoint) -> CGPoint {
        let ax = b.x - a.x, ay = b.y - a.y
        let len2 = ax * ax + ay * ay
        guard len2 > 0 else { return CGPoint(x: 0.5, y: 0) }
        let dx = p.x - a.x, dy = p.y - a.y
        // Normale obtenue en tournant l'axe de +90° (vers le haut quand l'axe va vers la droite).
        return CGPoint(x: (dx * ax + dy * ay) / len2,
                       y: (dx * -ay + dy * ax) / len2)
    }

    /// Point normalisé Vision → pixels isotropes, y vers le haut (pas de retournement).
    static func isotropic(_ p: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)
    }

    /// Pupille et ouverture d'un œil dans son repère coin–coin.
    static func eyePosition(_ eye: EyeMeasurement, pupil: CGPoint,
                            imageSize: CGSize) -> (pupil: CGPoint, aperture: Double)? {
        let contour = eye.contour.map { isotropic($0, imageSize: imageSize) }
        guard let pair = corners(of: contour) else { return nil }
        let (a, b) = pair
        let p = position(of: isotropic(pupil, imageSize: imageSize), cornerA: a, cornerB: b)
        let ys = contour.map { position(of: $0, cornerA: a, cornerB: b).y }
        let aperture = Double((ys.max() ?? 0) - (ys.min() ?? 0))
        return (p, aperture)
    }

    /// Mesures d'un visage avec la méthode de pupille choisie ; `nil` s'il manque un œil ou une pupille.
    static func make(from face: FaceMeasurement, imageSize: CGSize,
                     locator: PupilLocatorKind) -> GazeFeatures? {
        guard let left = face.leftEye, let right = face.rightEye,
              let lp = left.pupil(locator), let rp = right.pupil(locator),
              let l = eyePosition(left, pupil: lp, imageSize: imageSize),
              let r = eyePosition(right, pupil: rp, imageSize: imageSize)
        else { return nil }
        return GazeFeatures(
            leftPupilX: Double(l.pupil.x), leftPupilY: Double(l.pupil.y),
            rightPupilX: Double(r.pupil.x), rightPupilY: Double(r.pupil.y),
            aperture: (l.aperture + r.aperture) / 2,
            yaw: face.yaw, pitch: face.pitch, roll: face.roll,
            faceCenterX: Double(face.boundingBox.midX),
            faceCenterY: Double(face.boundingBox.midY),
            faceSize: Double(face.boundingBox.width))
    }
}
