import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class FaceQualityTests: XCTestCase {
    private let thresholds = FaceQuality.Thresholds(minFaceConfidence: 0.5, minEyeOpenness: 0.15, minFPS: 25)

    private func eye(openness: Double) -> EyeMeasurement {
        EyeMeasurement(contour: [], box: CGRect(x: 0, y: 0, width: 0.05, height: 0.02),
                       openness: openness, visionPupil: nil)
    }

    private func frame(confidence: Double = 0.9, openness: Double? = 0.3) -> FaceFrame {
        let face = FaceMeasurement(
            boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4),
            faceConfidence: confidence, landmarksConfidence: confidence,
            yaw: 0, pitch: 0, roll: 0, regions: [],
            leftEye: openness.map(eye(openness:)), rightEye: openness.map(eye(openness:)))
        return FaceFrame(imageSize: CGSize(width: 1920, height: 1080), face: face, processingTime: 0.01, timestamp: 0)
    }

    func testGoodFrameHasNoWarning() {
        XCTAssertEqual(FaceQuality.warnings(for: frame(), fps: 30, thresholds: thresholds), [])
    }

    func testNoFrameYetHasNoWarning() {
        XCTAssertEqual(FaceQuality.warnings(for: nil, fps: 0, thresholds: thresholds), [])
    }

    func testMissingFace() {
        let f = FaceFrame(imageSize: CGSize(width: 1280, height: 720), face: nil, processingTime: 0, timestamp: 0)
        XCTAssertEqual(FaceQuality.warnings(for: f, fps: 30, thresholds: thresholds), [.noFace])
    }

    func testLowConfidence() {
        XCTAssertEqual(FaceQuality.warnings(for: frame(confidence: 0.3), fps: 30, thresholds: thresholds), [.lowConfidence])
    }

    func testClosedOrMissingEyes() {
        XCTAssertEqual(FaceQuality.warnings(for: frame(openness: 0.05), fps: 30, thresholds: thresholds), [.eyesBarelyOpen])
        XCTAssertEqual(FaceQuality.warnings(for: frame(openness: nil), fps: 30, thresholds: thresholds), [.eyesBarelyOpen])
    }

    func testLowFrameRate() {
        XCTAssertEqual(FaceQuality.warnings(for: frame(), fps: 12, thresholds: thresholds), [.lowFrameRate])
    }

    func testFaceGeometryHelpers() {
        let box = FaceGeometry.boundingBox(of: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.45, y: 0.48)])
        XCTAssertEqual(box.minX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(box.maxY, 0.52, accuracy: 1e-9)
        XCTAssertTrue(FaceGeometry.boundingBox(of: []).isNull)

        // 0.1 × 1920 = 192 px de large, 0.1 × 1080 = 108 px de haut.
        XCTAssertEqual(FaceGeometry.openness(of: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                             imageSize: CGSize(width: 1920, height: 1080)), 108.0 / 192.0, accuracy: 1e-9)

        let a = CGRect(x: 0, y: 0, width: 2, height: 2)
        XCTAssertEqual(FaceGeometry.intersectionOverUnion(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(FaceGeometry.intersectionOverUnion(a, CGRect(x: 1, y: 0, width: 2, height: 2)), 2.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(FaceGeometry.intersectionOverUnion(a, CGRect(x: 5, y: 5, width: 1, height: 1)), 0)
    }
}
