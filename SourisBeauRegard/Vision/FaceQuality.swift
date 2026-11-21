import Foundation

/// Avertissements de qualité affichés dans la fenêtre de débogage
/// (contre-jour, reflets sur des lunettes, visage hors champ, caméra lente…).
/// Logique pure, testée dans `FaceQualityTests`.
enum FaceQuality {
    struct Thresholds: Sendable, Equatable {
        var minFaceConfidence: Double
        var minEyeOpenness: Double
        var minFPS: Double
    }

    enum Warning: Sendable, Equatable, Hashable {
        case noFace
        case lowConfidence
        case eyesBarelyOpen
        case lowFrameRate

        var message: String {
            switch self {
            case .noFace: "Aucun visage détecté : placez-vous face à la caméra."
            case .lowConfidence: "Confiance de détection faible : vérifiez l'éclairage (contre-jour ?)."
            case .eyesBarelyOpen: "Yeux peu visibles : clignement, reflets sur des lunettes ou ombre."
            case .lowFrameRate: "Images par seconde trop basses : éclairez la pièce ou fermez des apps."
            }
        }
    }

    static func warnings(for frame: FaceFrame?, fps: Double, thresholds: Thresholds) -> [Warning] {
        guard let frame else { return [] }
        var result: [Warning] = []
        if let face = frame.face {
            if min(face.faceConfidence, face.landmarksConfidence) < thresholds.minFaceConfidence {
                result.append(.lowConfidence)
            }
            let opennesses = [face.leftEye?.openness, face.rightEye?.openness].compactMap { $0 }
            if opennesses.isEmpty || opennesses.contains(where: { $0 < thresholds.minEyeOpenness }) {
                result.append(.eyesBarelyOpen)
            }
        } else {
            result.append(.noFace)
        }
        if fps > 0, fps < thresholds.minFPS {
            result.append(.lowFrameRate)
        }
        return result
    }
}
