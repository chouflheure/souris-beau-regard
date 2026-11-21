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
    func testRelativePupilPosition() {
        let box = CGRect(x: 0.4, y: 0.5, width: 0.1, height: 0.04)
        let r = GazeFeatures.relative(CGPoint(x: 0.425, y: 0.53), in: box)
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.75, accuracy: 1e-9)
        XCTAssertEqual(GazeFeatures.relative(.zero, in: .zero), CGPoint(x: 0.5, y: 0.5))
    }

    func testMakeUsesChosenLocatorAndNeedsBothPupils() throws {
        let leftBox = CGRect(x: 0.4, y: 0.5, width: 0.1, height: 0.04)
        let rightBox = CGRect(x: 0.6, y: 0.5, width: 0.1, height: 0.04)
        let left = EyeMeasurement(contour: [], box: leftBox, openness: 0.3,
                                  visionPupil: CGPoint(x: 0.45, y: 0.52), imagePupil: CGPoint(x: 0.41, y: 0.52))
        var right = EyeMeasurement(contour: [], box: rightBox, openness: 0.3,
                                   visionPupil: CGPoint(x: 0.65, y: 0.52), imagePupil: CGPoint(x: 0.61, y: 0.52))
        var face = FaceMeasurement(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.5),
                                   faceConfidence: 1, landmarksConfidence: 1, yaw: 0.1, pitch: -0.2, roll: 0.05,
                                   regions: [], leftEye: left, rightEye: right)

        let vision = try XCTUnwrap(GazeFeatures.make(from: face, locator: .vision))
        XCTAssertEqual(vision.leftPupilX, 0.5, accuracy: 1e-9)
        let image = try XCTUnwrap(GazeFeatures.make(from: face, locator: .image))
        XCTAssertEqual(image.leftPupilX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(image.yaw, 0.1)
        XCTAssertEqual(image.faceCenterX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(image.faceSize, 0.4, accuracy: 1e-9)
        XCTAssertEqual(image.vector.count, GazeFeatures.count)

        right.imagePupil = nil
        face.rightEye = right
        XCTAssertNil(GazeFeatures.make(from: face, locator: .image))
        XCTAssertNotNil(GazeFeatures.make(from: face, locator: .vision))
    }
}

final class CalibrationPlanTests: XCTestCase {
    func testGridIsThreeByThreeAtEightPercent() {
        let grid = CalibrationPlan.calibrationGrid
        XCTAssertEqual(grid.count, 9)
        XCTAssertEqual(Set(grid.map(\.x)), [0.08, 0.5, 0.92])
        XCTAssertEqual(Set(grid.map(\.y)), [0.08, 0.5, 0.92])
        var g = SystemRandomNumberGenerator()
        let shuffled = CalibrationPlan.calibrationPoints(using: &g)
        XCTAssertEqual(Set(shuffled.map { "\($0.x),\($0.y)" }), Set(grid.map { "\($0.x),\($0.y)" }))
        XCTAssertEqual(CalibrationPlan.validationPoints.count, 5)
    }

    private func sample(_ elapsed: Double, pupil: Double = 0.5, openness: Double = 0.3) -> CalibrationPlan.TimedSample {
        let f = GazeFeatures(leftPupilX: pupil, leftPupilY: 0.5, rightPupilX: pupil, rightPupilY: 0.5,
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
