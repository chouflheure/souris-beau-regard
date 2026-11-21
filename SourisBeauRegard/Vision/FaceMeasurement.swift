import CoreGraphics

/// Résultats de l'analyse d'une image, extraits des objets Vision sur la file de capture.
/// Types purs et `Sendable` : ils traversent les files sans référence à Vision ni AVFoundation.

/// Un groupe de repères du visage, en coordonnées normalisées Vision de l'image (origine bas-gauche).
struct LandmarkRegion: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case faceContour, eye, eyebrow, nose, lips, medianLine, pupil
    }
    var kind: Kind
    var points: [CGPoint]
    var closed: Bool
}

/// Mesures d'un œil.
struct EyeMeasurement: Sendable, Equatable {
    /// Contour de l'œil, normalisé Vision de l'image.
    var contour: [CGPoint]
    /// Boîte englobante du contour, normalisée Vision de l'image.
    var box: CGRect
    /// Hauteur / largeur de la boîte, calculées en pixels (pour ne pas dépendre du format d'image).
    var openness: Double
    /// Point « pupille » fourni par Vision, normalisé Vision de l'image.
    var visionPupil: CGPoint?
    /// Pupille trouvée dans l'image (zone la plus sombre), normalisée Vision de l'image.
    var imagePupil: CGPoint? = nil

    func pupil(_ kind: PupilLocatorKind) -> CGPoint? {
        switch kind {
        case .vision: visionPupil
        case .image: imagePupil
        }
    }
}

/// Les deux façons de localiser la pupille, à comparer dans la fenêtre de débogage.
enum PupilLocatorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case vision
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vision: "Vision (repères)"
        case .image: "Image (zone sombre)"
        }
    }
}

/// Tout ce qu'on sait du visage principal dans une image.
struct FaceMeasurement: Sendable, Equatable {
    /// Boîte du visage, normalisée Vision.
    var boundingBox: CGRect
    /// Confiance de détection du visage (0…1).
    var faceConfidence: Double
    /// Confiance des repères (0…1).
    var landmarksConfidence: Double
    /// Angles de la tête en radians.
    var yaw: Double
    var pitch: Double
    var roll: Double
    var regions: [LandmarkRegion]
    /// Œil gauche / droit **de l'image** (pas de la personne) — même convention que Vision.
    var leftEye: EyeMeasurement?
    var rightEye: EyeMeasurement?
}

/// Résultat complet pour une image de la caméra.
struct FaceFrame: Sendable, Equatable {
    /// Taille de l'image en pixels.
    var imageSize: CGSize
    var face: FaceMeasurement?
    /// Durée de l'analyse Vision, en secondes.
    var processingTime: Double
    /// Horodatage de l'image (secondes, horloge de la capture).
    var timestamp: Double
}

/// Petites fonctions de calcul utilisées par `FaceAnalyzer`, isolées pour être testées.
enum FaceGeometry {
    /// Boîte englobante d'un nuage de points.
    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Ouverture de l'œil : hauteur / largeur de sa boîte, mesurées en pixels.
    static func openness(of normalizedBox: CGRect, imageSize: CGSize) -> Double {
        let w = normalizedBox.width * imageSize.width
        let h = normalizedBox.height * imageSize.height
        guard w > 0 else { return 0 }
        return Double(h / w)
    }

    /// Le point est-il dans le polygone ? (lancer de rayon)
    static func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Recouvrement (intersection sur union) de deux rectangles, 0…1.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? Double(inter / union) : 0
    }
}
