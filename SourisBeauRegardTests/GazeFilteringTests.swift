import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class OneEuroFilterTests: XCTestCase {
    func testFirstValuePassesThroughAndConstantStaysConstant() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0.01)
        XCTAssertEqual(f.filter(42, timestamp: 0), 42)
        for i in 1...30 {
            XCTAssertEqual(f.filter(42, timestamp: Double(i) / 30), 42, accuracy: 1e-9)
        }
    }

    func testReducesJitterAtRest() {
        var f = OneEuroFilter(minCutoff: 0.8, beta: 0.006)
        var outputs: [Double] = []
        for i in 0..<120 {
            let noisy = 500 + (i.isMultiple(of: 2) ? 20.0 : -20.0)
            outputs.append(f.filter(noisy, timestamp: Double(i) / 30))
        }
        let tail = outputs.suffix(30)
        let spread = (tail.max() ?? 0) - (tail.min() ?? 0)
        XCTAssertLessThan(spread, 15, "40 points de tremblement doivent être fortement atténués")
    }

    func testConvergesAfterStep() {
        var f = OneEuroFilter(minCutoff: 0.8, beta: 0.006)
        _ = f.filter(0, timestamp: 0)
        var last = 0.0
        for i in 1...60 { last = f.filter(1000, timestamp: Double(i) / 30) }
        XCTAssertEqual(last, 1000, accuracy: 5)
    }

    func testHigherBetaMeansLessLag() {
        func valueAfterStep(beta: Double) -> Double {
            var f = OneEuroFilter(minCutoff: 0.5, beta: beta)
            _ = f.filter(0, timestamp: 0)
            var v = 0.0
            for i in 1...3 { v = f.filter(1000, timestamp: Double(i) / 30) }
            return v
        }
        XCTAssertGreaterThan(valueAfterStep(beta: 0.02), valueAfterStep(beta: 0))
    }

    func testDuplicateTimestampDoesNotProduceNaN() {
        var f = OneEuroFilter()
        _ = f.filter(1, timestamp: 1)
        let v = f.filter(2, timestamp: 1)
        XCTAssertFalse(v.isNaN)
    }

    func testResetForgetsHistory() {
        var f = OneEuroFilter()
        _ = f.filter(0, timestamp: 0)
        f.reset()
        XCTAssertEqual(f.filter(500, timestamp: 0.1), 500)
    }
}

final class FixationDetectorTests: XCTestCase {
    func testSteadyGazeBecomesFixationAfterMinDuration() {
        var d = FixationDetector(minDuration: 0.15, maxDispersion: 50)
        var results: [CGPoint?] = []
        for i in 0..<10 {
            results.append(d.add(CGPoint(x: 100 + Double(i % 3), y: 200), time: Double(i) / 30))
        }
        XCTAssertNil(results[0])
        XCTAssertNil(results[3])           // 0,1 s
        XCTAssertNotNil(results[5])        // 0,167 s
        let c = try? XCTUnwrap(results[9])
        XCTAssertEqual(c?.x ?? 0, 101, accuracy: 1)
        XCTAssertEqual(c?.y ?? 0, 200, accuracy: 1e-9)
    }

    func testSaccadeEndsFixation() {
        var d = FixationDetector(minDuration: 0.1, maxDispersion: 50)
        for i in 0..<10 { _ = d.add(CGPoint(x: 100, y: 100), time: Double(i) / 30) }
        XCTAssertTrue(d.isFixating)
        XCTAssertNil(d.add(CGPoint(x: 600, y: 400), time: 0.4))
        XCTAssertFalse(d.isFixating)
        // Nouvelle fixation au nouvel endroit.
        var c: CGPoint?
        for i in 1...6 { c = d.add(CGPoint(x: 600, y: 400), time: 0.4 + Double(i) / 30) }
        XCTAssertEqual(c, CGPoint(x: 600, y: 400))
    }

    func testFixationCentroidIsStableUnderNoise() {
        var d = FixationDetector(minDuration: 0.1, maxDispersion: 60)
        var c: CGPoint?
        for i in 0..<60 {
            let jitter = i.isMultiple(of: 2) ? 12.0 : -12.0
            c = d.add(CGPoint(x: 300 + jitter, y: 300 - jitter), time: Double(i) / 30)
        }
        XCTAssertEqual(c?.x ?? 0, 300, accuracy: 1)
        XCTAssertEqual(c?.y ?? 0, 300, accuracy: 1)
    }

    func testSlowDriftIsNotAFixationIfTooDispersed() {
        var d = FixationDetector(minDuration: 0.2, maxDispersion: 30)
        var last: CGPoint?
        for i in 0..<30 { last = d.add(CGPoint(x: Double(i) * 40, y: 0), time: Double(i) / 30) }
        XCTAssertNil(last)
    }

    func testDispersion() {
        let s = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 4, y: -5)]
            .map { FixationDetector.Sample(point: $0, time: 0) }
        XCTAssertEqual(FixationDetector.dispersion(s), 20)
    }
}

final class GazeEngineTests: XCTestCase {
    func testClampsToScreenAndReportsFixation() {
        var engine = GazeEngine(parameters: GazeParameters(minCutoff: 1, beta: 0.01, derivativeCutoff: 1,
                                                          fixationDuration: 0.1, fixationDispersion: 50))
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var estimate: GazeEstimate?
        for i in 0..<15 {
            estimate = engine.process(raw: CGPoint(x: 1200, y: -50), timestamp: Double(i) / 30, bounds: screen)
        }
        XCTAssertEqual(estimate?.raw, CGPoint(x: 1000, y: 0))
        XCTAssertEqual(estimate?.point.x ?? 0, 1000, accuracy: 1e-6)
        XCTAssertNotNil(estimate?.fixation)
    }
}
