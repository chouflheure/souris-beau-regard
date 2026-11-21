import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class CoordinateSpacesTests: XCTestCase {
    private let accuracy: CGFloat = 1e-9

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    private func assertEqual(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Vision

    func testLandmarkToImageUsesFaceBox() {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        assertEqual(CoordinateSpaces.landmarkToImage(.zero, faceBoundingBox: box), CGPoint(x: 0.2, y: 0.3))
        assertEqual(CoordinateSpaces.landmarkToImage(CGPoint(x: 1, y: 1), faceBoundingBox: box), CGPoint(x: 0.6, y: 0.8))
        assertEqual(CoordinateSpaces.landmarkToImage(CGPoint(x: 0.5, y: 0.5), faceBoundingBox: box), CGPoint(x: 0.4, y: 0.55))
    }

    func testVisionToImagePixelsFlipsY() {
        let size = CGSize(width: 1920, height: 1080)
        assertEqual(CoordinateSpaces.visionToImagePixels(.zero, imageSize: size), CGPoint(x: 0, y: 1080))
        assertEqual(CoordinateSpaces.visionToImagePixels(CGPoint(x: 1, y: 1), imageSize: size), CGPoint(x: 1920, y: 0))
        assertEqual(CoordinateSpaces.visionToImagePixels(CGPoint(x: 0.25, y: 0.75), imageSize: size), CGPoint(x: 480, y: 270))
    }

    func testVisionRectToImagePixels() {
        let size = CGSize(width: 1000, height: 500)
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        // Haut du rectangle en Vision : y = 0.6 → 0.4 depuis le haut → 200 px.
        assertEqual(CoordinateSpaces.visionRectToImagePixels(rect, imageSize: size),
                    CGRect(x: 100, y: 200, width: 300, height: 200))
    }

    func testVisionToViewWithAndWithoutMirror() {
        let imageRect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let p = CGPoint(x: 0.25, y: 0.25)
        assertEqual(CoordinateSpaces.visionToView(p, imageRect: imageRect, mirrored: false), CGPoint(x: 60, y: 95))
        assertEqual(CoordinateSpaces.visionToView(p, imageRect: imageRect, mirrored: true), CGPoint(x: 160, y: 95))
    }

    func testVisionRectToViewIsStandardizedWhenMirrored() {
        let imageRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
        assertEqual(CoordinateSpaces.visionRectToView(rect, imageRect: imageRect, mirrored: false),
                    CGRect(x: 10, y: 60, width: 20, height: 30))
        assertEqual(CoordinateSpaces.visionRectToView(rect, imageRect: imageRect, mirrored: true),
                    CGRect(x: 70, y: 60, width: 20, height: 30))
    }

    func testAspectFitLetterboxesAndPillarboxes() {
        let content = CGSize(width: 1920, height: 1080)
        assertEqual(CoordinateSpaces.aspectFitRect(contentSize: content, in: CGRect(x: 0, y: 0, width: 400, height: 400)),
                    CGRect(x: 0, y: 87.5, width: 400, height: 225))
        assertEqual(CoordinateSpaces.aspectFitRect(contentSize: content, in: CGRect(x: 0, y: 0, width: 1000, height: 270)),
                    CGRect(x: 260, y: 0, width: 480, height: 270))
        XCTAssertEqual(CoordinateSpaces.aspectFitRect(contentSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)), .zero)
    }

    // MARK: AppKit ↔ Quartz

    func testAppKitQuartzPointRoundTrip() {
        let h: CGFloat = 1117
        let appKit = CGPoint(x: 300, y: 100)
        let quartz = CoordinateSpaces.appKitToQuartz(appKit, primaryScreenHeight: h)
        assertEqual(quartz, CGPoint(x: 300, y: 1017))
        assertEqual(CoordinateSpaces.quartzToAppKit(quartz, primaryScreenHeight: h), appKit)
    }

    func testAppKitQuartzRectUsesTopEdge() {
        let h: CGFloat = 1000
        let appKit = CGRect(x: 10, y: 100, width: 50, height: 20)
        let quartz = CoordinateSpaces.appKitRectToQuartz(appKit, primaryScreenHeight: h)
        assertEqual(quartz, CGRect(x: 10, y: 880, width: 50, height: 20))
        assertEqual(CoordinateSpaces.quartzRectToAppKit(quartz, primaryScreenHeight: h), appKit)
    }

    func testSecondaryScreenAboveMainHasNegativeQuartzY() {
        // Écran secondaire posé au-dessus de l'écran principal (1000 pt de haut).
        let secondaryAppKit = CGRect(x: 0, y: 1000, width: 1920, height: 1080)
        let quartz = CoordinateSpaces.appKitRectToQuartz(secondaryAppKit, primaryScreenHeight: 1000)
        assertEqual(quartz, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    // MARK: Écran normalisé

    func testNormalizedScreenRoundTrip() {
        let frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let n = CGPoint(x: 0.5, y: 0.25)
        let q = CoordinateSpaces.normalizedToQuartz(n, screenFrameQuartz: frame)
        assertEqual(q, CGPoint(x: -960, y: 270))
        assertEqual(CoordinateSpaces.quartzToNormalized(q, screenFrameQuartz: frame), n)
    }
}
