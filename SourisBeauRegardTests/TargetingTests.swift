import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class TargetingTests: XCTestCase {
    private func target(_ name: String, x: CGFloat, y: CGFloat, w: CGFloat = 40, h: CGFloat = 20) -> TargetCandidate {
        let frame = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
        return TargetCandidate(id: name, frame: frame, role: "AXButton", title: name, pid: 42)
    }

    // MARK: Géométrie

    func testSamplePointsGridStartsAtCenter() {
        let points = TargetGeometry.samplePoints(around: CGPoint(x: 100, y: 200), radius: 120, gridSize: 5)
        XCTAssertEqual(points.count, 25)
        XCTAssertEqual(points.first, CGPoint(x: 100, y: 200))
        XCTAssertEqual(points.map(\.x).min(), -20)
        XCTAssertEqual(points.map(\.x).max(), 220)
        XCTAssertEqual(points.map(\.y).min(), 80)
        XCTAssertEqual(Set(points.map(\.x)).count, 5)
        XCTAssertEqual(TargetGeometry.samplePoints(around: .zero, radius: 50, gridSize: 1), [.zero])
    }

    func testNearestUsesCenterDistanceAndRadius() {
        let a = target("a", x: 100, y: 100)
        let b = target("b", x: 160, y: 100)
        XCTAssertEqual(TargetGeometry.nearest([a, b], to: CGPoint(x: 120, y: 100), radius: 120)?.id, "a")
        XCTAssertEqual(TargetGeometry.nearest([a, b], to: CGPoint(x: 140, y: 100), radius: 120)?.id, "b")
        XCTAssertNil(TargetGeometry.nearest([a], to: CGPoint(x: 400, y: 100), radius: 120))
        // Grande cible : le regard est dedans mais loin du centre → gardée quand même.
        let big = target("big", x: 500, y: 500, w: 600, h: 40)
        XCTAssertEqual(TargetGeometry.nearest([big], to: CGPoint(x: 760, y: 500), radius: 120)?.id, "big")
    }

    func testCacheCellAndID() {
        XCTAssertEqual(TargetGeometry.cacheCell(for: CGPoint(x: 39, y: -1), cellSize: 20), "1,-1")
        XCTAssertEqual(TargetCandidate.makeID(pid: 7, role: "AXLink", frame: CGRect(x: 1.4, y: 2.6, width: 10, height: 5)),
                       "7|AXLink|1,3,10,5")
    }

    // MARK: Hystérésis

    func testSelectorWaitsBeforeAcquiringAndSwitching() {
        var s = TargetSelector(hysteresis: 0.15, radius: 120, stickiness: 0)
        let a = target("a", x: 100, y: 100)
        let b = target("b", x: 200, y: 100)

        XCTAssertNil(s.update(candidates: [a, b], gaze: CGPoint(x: 100, y: 100), time: 0))
        XCTAssertNil(s.update(candidates: [a, b], gaze: CGPoint(x: 100, y: 100), time: 0.1))
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 100, y: 100), time: 0.16)?.id, "a")

        // Regard bref vers b : pas de changement.
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 200, y: 100), time: 0.2)?.id, "a")
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 100, y: 100), time: 0.25)?.id, "a")
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 200, y: 100), time: 0.3)?.id, "a")
        // b reste le plus proche 150 ms : on change.
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 200, y: 100), time: 0.4)?.id, "a")
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 200, y: 100), time: 0.46)?.id, "b")
    }

    func testSelectorDoesNotFlickerBetweenNeighbours() {
        var s = TargetSelector(hysteresis: 0.15, radius: 120, stickiness: 0)
        let a = target("a", x: 100, y: 100)
        let b = target("b", x: 140, y: 100)
        for i in 0..<10 { s.update(candidates: [a, b], gaze: CGPoint(x: 105, y: 100), time: Double(i) * 0.033) }
        XCTAssertEqual(s.current?.id, "a")
        var changes = 0
        var last = s.current?.id
        // Le regard oscille autour de la frontière à chaque image.
        for i in 10..<60 {
            let x: CGFloat = i.isMultiple(of: 2) ? 115 : 125
            let id = s.update(candidates: [a, b], gaze: CGPoint(x: x, y: 100), time: Double(i) * 0.033)?.id
            if id != last { changes += 1; last = id }
        }
        XCTAssertEqual(changes, 0)
    }

    func testSelectorLosesTargetOnlyAfterHysteresis() {
        var s = TargetSelector(hysteresis: 0.15, radius: 120)
        let a = target("a", x: 100, y: 100)
        s.update(candidates: [a], gaze: CGPoint(x: 100, y: 100), time: 0)
        s.update(candidates: [a], gaze: CGPoint(x: 100, y: 100), time: 0.2)
        XCTAssertEqual(s.current?.id, "a")
        XCTAssertEqual(s.update(candidates: [], gaze: CGPoint(x: 600, y: 600), time: 0.25)?.id, "a")
        XCTAssertNil(s.update(candidates: [], gaze: CGPoint(x: 600, y: 600), time: 0.41))
    }

    func testSelectorRefreshesFrameOfSameTarget() {
        var s = TargetSelector(hysteresis: 0, radius: 120)
        var a = target("a", x: 100, y: 100)
        s.update(candidates: [a], gaze: CGPoint(x: 100, y: 100), time: 0)
        s.update(candidates: [a], gaze: CGPoint(x: 100, y: 100), time: 0.01)
        a.frame = a.frame.offsetBy(dx: 5, dy: 0)
        XCTAssertEqual(s.update(candidates: [a], gaze: CGPoint(x: 100, y: 100), time: 0.02)?.frame, a.frame)
    }

    func testStickinessKeepsTargetWhileGazeStaysNearIt() {
        var s = TargetSelector(hysteresis: 0.15, radius: 120, stickiness: 40)
        let a = target("a", x: 100, y: 100)            // 80…120 × 90…110
        let b = target("b", x: 170, y: 100)
        s.update(candidates: [a, b], gaze: CGPoint(x: 100, y: 100), time: 0)
        s.update(candidates: [a, b], gaze: CGPoint(x: 100, y: 100), time: 0.2)
        XCTAssertEqual(s.current?.id, "a")
        // Le regard dérive à 150 (plus près de b) mais reste à moins de 40 pt du bord de a : a reste, longtemps.
        for i in 0..<20 {
            XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 150, y: 100), time: 0.3 + Double(i) * 0.05)?.id, "a")
        }
        // La recherche rate a sur une image : on la garde quand même.
        XCTAssertEqual(s.update(candidates: [b], gaze: CGPoint(x: 110, y: 100), time: 1.5)?.id, "a")
        // Le regard sort de la zone élargie et reste sur b 150 ms : changement.
        s.update(candidates: [a, b], gaze: CGPoint(x: 175, y: 100), time: 2.0)
        XCTAssertEqual(s.update(candidates: [a, b], gaze: CGPoint(x: 175, y: 100), time: 2.2)?.id, "b")
    }

    // MARK: Historique

    func testHistoryReturnsTargetInForceAtTime() {
        var h = TargetHistory()
        let a = target("a", x: 0, y: 0)
        let b = target("b", x: 100, y: 0)
        h.record(a, at: 1.0)
        h.record(a, at: 1.05)
        h.record(b, at: 1.2)
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.target(at: 1.1)?.id, "a")       // 120 ms avant l'appui à 1,22
        XCTAssertEqual(h.target(at: 1.25)?.id, "b")
        XCTAssertNil(h.target(at: 0.5))
        h.record(nil, at: 3.0)
        XCTAssertNil(h.target(at: 3.1))
        XCTAssertEqual(h.target(at: 2.5)?.id, "b", "l'entrée en vigueur au début de la fenêtre est gardée")
    }
}
