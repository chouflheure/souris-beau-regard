import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class DarkCentroidTests: XCTestCase {
    /// Image claire (200) avec un carré sombre (20) de 3×3 pixels en (12…14, 4…6).
    private func image() -> (gray: [UInt8], width: Int, height: Int) {
        let w = 20, h = 10
        var g = [UInt8](repeating: 200, count: w * h)
        for y in 4...6 { for x in 12...14 { g[y * w + x] = 20 } }
        return (g, w, h)
    }

    func testFindsDarkSpotCenter() throws {
        let (g, w, h) = image()
        let c = try XCTUnwrap(DarkCentroid.locate(gray: g, width: w, height: h, polygon: nil, darkFraction: 0.04))
        XCTAssertEqual(c.x, 13.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 5.5, accuracy: 1e-9)
    }

    func testIgnoresDarkPixelsOutsidePolygon() throws {
        let (base, w, h) = image()
        var g = base
        // Tache sombre parasite (sourcil, cils) hors du contour, en haut à gauche.
        for y in 0...1 { for x in 0...3 { g[y * w + x] = 0 } }
        let polygon = [CGPoint(x: 8, y: 2), CGPoint(x: 19, y: 2), CGPoint(x: 19, y: 9), CGPoint(x: 8, y: 9)]
        let c = try XCTUnwrap(DarkCentroid.locate(gray: g, width: w, height: h, polygon: polygon, darkFraction: 0.1))
        XCTAssertEqual(c.x, 13.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 5.5, accuracy: 1e-9)
    }

    /// Œil synthétique 50 × 20 : blanc (200), iris sombre (70) de rayon 6 centré en (25,5 ; 10,5),
    /// pupille (25) de rayon 2, et une rangée de cils très sombres (10) en haut.
    private func syntheticEye(withLashes: Bool = true) -> [UInt8] {
        let w = 50, h = 20
        var g = [UInt8](repeating: 200, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = hypot(Double(x) + 0.5 - 25.5, Double(y) + 0.5 - 10.5)
                if d <= 6 { g[y * w + x] = 70 }
                if d <= 2 { g[y * w + x] = 25 }
            }
        }
        if withLashes { for y in 0...1 { for x in 5...44 { g[y * w + x] = 10 } } }
        return g
    }

    func testIrisSearchIgnoresEyelashes() throws {
        let g = syntheticEye()
        let c = try XCTUnwrap(DarkCentroid.locateIris(gray: g, width: 50, height: 20, polygon: nil, boxSide: 9))
        XCTAssertEqual(c.x, 25.5, accuracy: 1)
        XCTAssertEqual(c.y, 10.5, accuracy: 1)
        // L'ancienne méthode (pixels les plus sombres) est attirée par les cils.
        let old = try XCTUnwrap(DarkCentroid.locate(gray: g, width: 50, height: 20, polygon: nil, darkFraction: 0.12))
        XCTAssertLessThan(old.y, 5)
    }

    func testIrisSearchWithPolygonAndOffCenterIris() throws {
        let w = 50, h = 20
        var g = [UInt8](repeating: 200, count: w * h)
        for y in 0..<h { for x in 0..<w where hypot(Double(x) + 0.5 - 15.5, Double(y) + 0.5 - 9.5) <= 5 { g[y * w + x] = 60 } }
        let polygon = [CGPoint(x: 2, y: 10), CGPoint(x: 25, y: 1), CGPoint(x: 48, y: 10), CGPoint(x: 25, y: 19)]
        let c = try XCTUnwrap(DarkCentroid.locateIris(gray: g, width: w, height: h, polygon: polygon, boxSide: 7))
        XCTAssertEqual(c.x, 15.5, accuracy: 1)
        XCTAssertEqual(c.y, 9.5, accuracy: 1)
        XCTAssertNil(DarkCentroid.locateIris(gray: [1, 2], width: 2, height: 2, polygon: nil, boxSide: 2))
    }

    /// Cas observé : le contour de Vision est trop bas et coupe le haut de l'iris.
    func testIrisAboveVisionContourIsFoundWithEnlargedZone() throws {
        let w = 50, h = 30
        var g = [UInt8](repeating: 200, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = hypot(Double(x) + 0.5 - 25.5, Double(y) + 0.5 - 10.5)
                if d <= 6 { g[y * w + x] = 70 }
                if d <= 2 { g[y * w + x] = 25 }
            }
        }
        let contour = [CGPoint(x: 5, y: 18), CGPoint(x: 25, y: 12), CGPoint(x: 45, y: 18), CGPoint(x: 25, y: 24)]
        let found = try XCTUnwrap(DarkCentroid.locateIris(gray: g, width: w, height: h, polygon: contour, boxSide: 9,
                                                          maskScaleX: ImagePupilLocator.maskScaleX,
                                                          maskScaleY: ImagePupilLocator.maskScaleY))
        XCTAssertEqual(found.x, 25.5, accuracy: 1)
        XCTAssertEqual(found.y, 10.5, accuracy: 1)
        // Avec le contour rétréci (ancienne zone), la croix restait collée au bord du contour.
        let old = try XCTUnwrap(DarkCentroid.locateIris(gray: g, width: w, height: h, polygon: contour, boxSide: 9))
        XCTAssertGreaterThan(old.y, 13)
    }

    func testRejectsInconsistentSize() {
        XCTAssertNil(DarkCentroid.locate(gray: [1, 2, 3], width: 2, height: 2, polygon: nil, darkFraction: 0.1))
    }

    func testPolygonContains() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertTrue(FaceGeometry.polygon(square, contains: CGPoint(x: 5, y: 5)))
        XCTAssertFalse(FaceGeometry.polygon(square, contains: CGPoint(x: 15, y: 5)))
        XCTAssertFalse(FaceGeometry.polygon([CGPoint.zero, CGPoint(x: 1, y: 1)], contains: .zero))
    }

    func testImagePixelsToVisionIsInverseOfVisionToImagePixels() {
        let size = CGSize(width: 1920, height: 1080)
        let v = CGPoint(x: 0.3, y: 0.8)
        let back = CoordinateSpaces.imagePixelsToVision(CoordinateSpaces.visionToImagePixels(v, imageSize: size), imageSize: size)
        XCTAssertEqual(back.x, v.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, v.y, accuracy: 1e-12)
    }
}

final class GazeFeaturesTests: XCTestCase {
    func testCornersAreFarthestPairLeftFirst() throws {
        let contour = [CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 2), CGPoint(x: 0, y: 0), CGPoint(x: 5, y: -2)]
        let (a, b) = try XCTUnwrap(GazeFeatures.corners(of: contour))
        XCTAssertEqual(a, CGPoint(x: 0, y: 0))
        XCTAssertEqual(b, CGPoint(x: 10, y: 0))
        XCTAssertNil(GazeFeatures.corners(of: [CGPoint.zero]))
    }

    func testPositionInEyeFrame() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        let p = GazeFeatures.position(of: CGPoint(x: 3, y: 1), cornerA: a, cornerB: b)
        XCTAssertEqual(p.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(p.y, 0.1, accuracy: 1e-12)
        // Œil penché (roulis 90°) : même position relative.
        let r = GazeFeatures.position(of: CGPoint(x: -1, y: 3), cornerA: a, cornerB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(r.y, 0.1, accuracy: 1e-12)
    }

    /// Œil horizontal de 100 × 30 px dans une image 1000 × 1000 (coordonnées Vision).
    private func eye(pupilX: Double, pupilY: Double, shift: Double = 0) -> EyeMeasurement {
        let contour = [CGPoint(x: 0.40, y: 0.50), CGPoint(x: 0.45, y: 0.515), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.45, y: 0.485)]
            .map { CGPoint(x: $0.x + shift, y: $0.y) }
        return EyeMeasurement(contour: contour, box: FaceGeometry.boundingBox(of: contour), openness: 0.3,
                              visionPupil: CGPoint(x: 0.45 + shift, y: 0.50),
                              imagePupil: CGPoint(x: pupilX + shift, y: pupilY))
    }

    func testMakeUsesChosenLocatorAndNeedsBothPupils() throws {
        let size = CGSize(width: 1000, height: 1000)
        var face = FaceMeasurement(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.5),
                                   faceConfidence: 1, landmarksConfidence: 1, yaw: 0.1, pitch: -0.2, roll: 0.05,
                                   regions: [], leftEye: eye(pupilX: 0.42, pupilY: 0.505),
                                   rightEye: eye(pupilX: 0.42, pupilY: 0.505, shift: 0.2))

        let vision = try XCTUnwrap(GazeFeatures.make(from: face, imageSize: size, locator: .vision))
        XCTAssertEqual(vision.leftPupilX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(vision.leftPupilY, 0, accuracy: 1e-9)
        let image = try XCTUnwrap(GazeFeatures.make(from: face, imageSize: size, locator: .image))
        XCTAssertEqual(image.leftPupilX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(image.leftPupilY, 0.05, accuracy: 1e-9)   // 5 px au-dessus, œil de 100 px
        XCTAssertEqual(image.aperture, 0.3, accuracy: 1e-9)      // 30 px / 100 px
        XCTAssertEqual(image.yaw, 0.1)
        XCTAssertEqual(image.rightPupilX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(image.faceCenterX, 0.55, accuracy: 1e-9)   // milieu des yeux (0,45 et 0,65)
        XCTAssertEqual(image.faceCenterY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(image.faceSize, 0.2, accuracy: 1e-9)       // 200 px entre les yeux / 1000 px
        XCTAssertEqual(image.vector.count, GazeFeatures.count)

        var right = eye(pupilX: 0.42, pupilY: 0.505, shift: 0.2)
        right.imagePupil = nil
        face.rightEye = right
        XCTAssertNil(GazeFeatures.make(from: face, imageSize: size, locator: .image))
        XCTAssertNotNil(GazeFeatures.make(from: face, imageSize: size, locator: .vision))
    }
}

final class CalibrationPlanTests: XCTestCase {
    func testGridIsThreeByThreeAtEightPercent() {
        let grid = CalibrationPlan.calibrationGrid
        XCTAssertEqual(grid.count, 9)
        XCTAssertEqual(Set(grid.map(\.x)), [0.08, 0.5, 0.92])
        XCTAssertEqual(Set(grid.map(\.y)), [0.08, 0.5, 0.92])
        var g = SystemRandomNumberGenerator()
        let shuffled = CalibrationPlan().calibrationPoints(using: &g)
        XCTAssertEqual(Set(shuffled.map { "\($0.x),\($0.y)" }), Set(grid.map { "\($0.x),\($0.y)" }))
        XCTAssertEqual(CalibrationPlan.validationPoints.count, 5)

        var plan = CalibrationPlan()
        plan.gridSize = 4
        let four = plan.calibrationPoints(using: &g)
        XCTAssertEqual(four.count, 16)
        XCTAssertEqual(four.map(\.x).min(), 0.08)
        XCTAssertEqual(four.map(\.x).max(), 0.92)
    }

    private func sample(_ elapsed: Double, pupil: Double = 0.5, openness: Double = 0.3) -> CalibrationPlan.TimedSample {
        let f = GazeFeatures(leftPupilX: pupil, leftPupilY: 0.5, rightPupilX: pupil, rightPupilY: 0.5, aperture: 0.3,
                             yaw: 0, pitch: 0, roll: 0, faceCenterX: 0.5, faceCenterY: 0.5, faceSize: 0.3)
        return .init(elapsed: elapsed, features: f, openness: openness)
    }

    func testFilterKeepsWindowAndDropsBlinksAndOutliers() {
        let plan = CalibrationPlan()
        var samples: [CalibrationPlan.TimedSample] = []
        samples.append(sample(0.2))                              // trop tôt
        samples.append(sample(1.6))                              // trop tard
        samples.append(sample(0.9, openness: 0.05))              // clignement
        for (i, t) in stride(from: 0.62, through: 1.48, by: 0.05).enumerated() {
            samples.append(sample(t, pupil: 0.5 + (i.isMultiple(of: 2) ? 0.004 : -0.004)))
        }
        samples.append(sample(1.0, pupil: 0.9))                  // aberrant
        let kept = plan.filter(samples)
        XCTAssertEqual(kept.count, 18)
        XCTAssertTrue(kept.allSatisfy { abs($0.leftPupilX - 0.5) < 0.01 })
    }

    func testMedian() {
        XCTAssertEqual(Stats.median([3, 1, 2]), 2)
        XCTAssertEqual(Stats.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(Stats.median([]), 0)
    }
}
