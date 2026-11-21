import CoreGraphics
import CoreVideo
import Vision

/// Détecte le visage principal et ses repères dans une image de la caméra.
///
/// N'est **pas** thread-safe : les requêtes Vision sont réutilisées d'une image à l'autre.
/// Une seule instance, possédée par `CameraService` et utilisée uniquement sur sa file de capture.
final class FaceAnalyzer {
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    private let rectanglesRequest = VNDetectFaceRectanglesRequest()

    init() {
        // Révision 3 : 76 repères dont les pupilles ; lacet, tangage et roulis sur les rectangles.
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
        rectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3
    }

    func analyze(pixelBuffer: CVPixelBuffer) -> FaceMeasurement? {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        // Les webcams du Mac livrent une image droite, non retournée.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([rectanglesRequest, landmarksRequest])
        } catch {
            return nil
        }
        guard let faces = landmarksRequest.results,
              let face = faces.max(by: { Self.area($0.boundingBox) < Self.area($1.boundingBox) })
        else { return nil }

        // Le rectangle correspondant (même visage) porte des angles plus fiables.
        let rect = rectanglesRequest.results?.max(by: {
            FaceGeometry.intersectionOverUnion($0.boundingBox, face.boundingBox)
                < FaceGeometry.intersectionOverUnion($1.boundingBox, face.boundingBox)
        })

        let box = face.boundingBox
        let landmarks = face.landmarks

        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map { CoordinateSpaces.landmarkToImage($0, faceBoundingBox: box) }
        }

        var regions: [LandmarkRegion] = []
        func add(_ region: VNFaceLandmarkRegion2D?, _ kind: LandmarkRegion.Kind, closed: Bool) {
            let pts = points(region)
            if !pts.isEmpty { regions.append(LandmarkRegion(kind: kind, points: pts, closed: closed)) }
        }
        add(landmarks?.faceContour, .faceContour, closed: false)
        add(landmarks?.leftEyebrow, .eyebrow, closed: false)
        add(landmarks?.rightEyebrow, .eyebrow, closed: false)
        add(landmarks?.leftEye, .eye, closed: true)
        add(landmarks?.rightEye, .eye, closed: true)
        add(landmarks?.noseCrest, .nose, closed: false)
        add(landmarks?.nose, .nose, closed: false)
        add(landmarks?.medianLine, .medianLine, closed: false)
        add(landmarks?.outerLips, .lips, closed: true)
        add(landmarks?.innerLips, .lips, closed: true)
        add(landmarks?.leftPupil, .pupil, closed: false)
        add(landmarks?.rightPupil, .pupil, closed: false)

        func eye(_ contourRegion: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?) -> EyeMeasurement? {
            let contour = points(contourRegion)
            guard contour.count >= 3 else { return nil }
            let eyeBox = FaceGeometry.boundingBox(of: contour)
            return EyeMeasurement(contour: contour,
                                  box: eyeBox,
                                  openness: FaceGeometry.openness(of: eyeBox, imageSize: imageSize),
                                  visionPupil: points(pupil).first)
        }

        return FaceMeasurement(
            boundingBox: box,
            faceConfidence: Double(face.confidence),
            landmarksConfidence: Double(landmarks?.confidence ?? 0),
            yaw: rect?.yaw?.doubleValue ?? face.yaw?.doubleValue ?? 0,
            pitch: rect?.pitch?.doubleValue ?? face.pitch?.doubleValue ?? 0,
            roll: rect?.roll?.doubleValue ?? face.roll?.doubleValue ?? 0,
            regions: regions,
            leftEye: eye(landmarks?.leftEye, pupil: landmarks?.leftPupil),
            rightEye: eye(landmarks?.rightEye, pupil: landmarks?.rightPupil)
        )
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}
