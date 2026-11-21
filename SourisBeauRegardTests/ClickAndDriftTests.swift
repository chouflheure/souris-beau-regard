import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class ClickLogicTests: XCTestCase {
    private let p = CGPoint(x: 400, y: 300)

    func testSimpleClickAtTarget() {
        var c = ClickLogic()
        XCTAssertEqual(c.press(at: p, time: 1, secondary: false), [.move(p), .leftDown(p, clickState: 1)])
        XCTAssertEqual(c.gazeMoved(to: CGPoint(x: 430, y: 300)), [], "petit mouvement du regard : pas de glisser")
        XCTAssertEqual(c.release(time: 1.1), [.leftUp(p, clickState: 1)])
        XCTAssertFalse(c.isPressed)
    }

    func testDoubleAndTripleClick() {
        var c = ClickLogic()
        _ = c.press(at: p, time: 1.0, secondary: false); _ = c.release(time: 1.05)
        // Second appui 200 ms plus tard, légèrement à côté : même point, clickState 2.
        XCTAssertEqual(c.press(at: CGPoint(x: 410, y: 305), time: 1.2, secondary: false), [.move(p), .leftDown(p, clickState: 2)])
        XCTAssertEqual(c.release(time: 1.25), [.leftUp(p, clickState: 2)])
        XCTAssertEqual(c.press(at: p, time: 1.4, secondary: false).last, .leftDown(p, clickState: 3))
        _ = c.release(time: 1.45)
        // Trop tard : nouveau clic simple.
        XCTAssertEqual(c.press(at: p, time: 2.5, secondary: false).last, .leftDown(p, clickState: 1))
    }

    func testFarSecondPressIsNotADoubleClick() {
        var c = ClickLogic()
        _ = c.press(at: p, time: 1.0, secondary: false); _ = c.release(time: 1.05)
        let q = CGPoint(x: 700, y: 300)
        XCTAssertEqual(c.press(at: q, time: 1.2, secondary: false), [.move(q), .leftDown(q, clickState: 1)])
    }

    func testDragFollowsGazeThenDrops() {
        var c = ClickLogic()
        _ = c.press(at: p, time: 1, secondary: false)
        XCTAssertEqual(c.gazeMoved(to: CGPoint(x: 450, y: 300)), [])
        let far = CGPoint(x: 520, y: 340)
        XCTAssertEqual(c.gazeMoved(to: far), [.leftDragged(far)])
        XCTAssertTrue(c.isDragging)
        let next = CGPoint(x: 600, y: 360)
        XCTAssertEqual(c.gazeMoved(to: next), [.leftDragged(next)])
        XCTAssertEqual(c.release(time: 2), [.leftUp(next, clickState: 1)])
        // Un glisser ne compte pas pour un double-clic.
        XCTAssertEqual(c.press(at: next, time: 2.1, secondary: false).last, .leftDown(next, clickState: 1))
    }

    func testRightClickWithControl() {
        var c = ClickLogic()
        XCTAssertEqual(c.press(at: p, time: 1, secondary: true), [.move(p), .rightDown(p)])
        XCTAssertEqual(c.gazeMoved(to: CGPoint(x: 900, y: 900)), [], "pas de glisser en clic droit")
        XCTAssertEqual(c.release(time: 1.1), [.rightUp(p)])
    }

    func testCancelReleasesButtonAndIgnoresRepeatedPress() {
        var c = ClickLogic()
        _ = c.press(at: p, time: 1, secondary: false)
        XCTAssertEqual(c.press(at: p, time: 1.01, secondary: false), [], "appui répété ignoré")
        XCTAssertEqual(c.cancel(), [.leftUp(p, clickState: 1)])
        XCTAssertEqual(c.cancel(), [])
        XCTAssertEqual(c.release(time: 2), [])
    }

    func testKeyCodesDistinguishRightAndLeftOption() {
        // Option droite enfoncée : bit 0x40 (et le drapeau général Option 0x80000).
        XCTAssertEqual(KeyCodes.isPressed(keyCode: KeyCodes.rightOption, flags: 0x0008_0040), true)
        // Seule l'Option gauche est enfoncée : la droite ne l'est pas.
        XCTAssertEqual(KeyCodes.isPressed(keyCode: KeyCodes.rightOption, flags: 0x0008_0020), false)
        XCTAssertNil(KeyCodes.isPressed(keyCode: 105, flags: 0))   // F13 : pas une touche de modification
        XCTAssertEqual(KeyCodes.name(for: 61), "Option droite")
    }

    func testPointHistory() {
        var h = PointHistory()
        h.record(CGPoint(x: 1, y: 1), at: 1.0)
        h.record(CGPoint(x: 2, y: 2), at: 1.1)
        h.record(CGPoint(x: 3, y: 3), at: 1.2)
        XCTAssertEqual(h.point(at: 1.15), CGPoint(x: 2, y: 2))
        XCTAssertNil(h.point(at: 0.5))
        h.record(CGPoint(x: 4, y: 4), at: 5.0)
        XCTAssertEqual(h.entries.count, 2)
    }
}

final class HeadDriftMonitorTests: XCTestCase {
    private let reference = HeadPose(x: 0.5, y: 0.5, size: 0.1)

    func testSmallMovementsDoNotSuggest() {
        var m = HeadDriftMonitor()
        for i in 0..<120 {
            let wobble = i.isMultiple(of: 2) ? 0.01 : -0.01   // ± 0,1 distance entre les yeux
            XCTAssertFalse(m.update(HeadPose(x: 0.5 + wobble, y: 0.5, size: 0.1), reference: reference, time: Double(i) / 30))
        }
    }

    func testSustainedLateralShiftSuggestsThenClearsWhenBack() {
        var m = HeadDriftMonitor()
        var results: [Bool] = []
        // Décalage de 0,08 (0,8 distance entre les yeux, au-delà du seuil de 0,5) pendant 3 s.
        for i in 0..<90 { results.append(m.update(HeadPose(x: 0.58, y: 0.5, size: 0.1), reference: reference, time: Double(i) / 30)) }
        XCTAssertFalse(results[30], "pas avant 1,5 s")
        XCTAssertTrue(results.last ?? false)
        // Retour à la position de référence : la proposition disparaît après environ 1 s.
        var back: [Bool] = []
        for i in 90..<180 { back.append(m.update(HeadPose(x: 0.5, y: 0.5, size: 0.1), reference: reference, time: Double(i) / 30)) }
        XCTAssertFalse(back.last ?? true)
    }

    func testMovingCloserSuggests() {
        var m = HeadDriftMonitor()
        var last = false
        for i in 0..<90 { last = m.update(HeadPose(x: 0.5, y: 0.5, size: 0.115), reference: reference, time: Double(i) / 30) }
        XCTAssertTrue(last, "15 % plus près")
    }

    func testAcknowledgeAndNoReference() {
        var m = HeadDriftMonitor()
        for i in 0..<90 { m.update(HeadPose(x: 0.6, y: 0.5, size: 0.1), reference: reference, time: Double(i) / 30) }
        XCTAssertTrue(m.suggestRecenter)
        m.acknowledge()
        XCTAssertFalse(m.suggestRecenter)
        var n = HeadDriftMonitor()
        XCTAssertFalse(n.update(HeadPose(x: 0.9, y: 0.9, size: 0.3), reference: nil, time: 0))
        XCTAssertNil(n.score)
    }

    func testDriftScoreUsesImageAspectForVerticalShift() {
        let pose = HeadPose(x: 0.5, y: 0.5 + 0.1 * 16 / 9 * 0.5, size: 0.1)   // 0,5 distance entre les yeux vers le bas
        let score = HeadDriftMonitor.driftScore(pose, reference: reference, lateralThreshold: 0.5,
                                                sizeThreshold: 0.12, aspect: 9.0 / 16.0)
        XCTAssertEqual(score, 1, accuracy: 1e-9)
    }
}
