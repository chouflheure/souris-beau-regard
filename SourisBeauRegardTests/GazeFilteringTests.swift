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

    func testNonFinitePointIsIgnored() {
        var d = FixationDetector(minDuration: 0.1, maxDispersion: 50)
        for i in 0..<10 { _ = d.add(CGPoint(x: 100, y: 100), time: Double(i) / 30) }
        XCTAssertEqual(d.add(CGPoint(x: CGFloat.nan, y: 0), time: 0.4), CGPoint(x: 100, y: 100))
        XCTAssertNil(d.add(CGPoint(x: 600, y: 600), time: 0.45), "une saccade doit toujours terminer la fixation")
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
        XCTAssertEqual(estimate?.isOffScreen, true)

        let inside = engine.process(raw: CGPoint(x: 1020, y: 10), timestamp: 1, bounds: screen)
        XCTAssertEqual(inside?.isOffScreen, false, "5 % de marge tolérée")
    }

    func testNonFiniteInputIsRejectedAndDoesNotPoisonFilters() {
        var engine = GazeEngine()
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        _ = engine.process(raw: CGPoint(x: 500, y: 400), timestamp: 0, bounds: screen)
        XCTAssertNil(engine.process(raw: CGPoint(x: CGFloat.nan, y: 400), timestamp: 0.033, bounds: screen))
        XCTAssertNil(engine.process(raw: CGPoint(x: CGFloat.infinity, y: 400), timestamp: 0.066, bounds: screen))
        let next = engine.process(raw: CGPoint(x: 500, y: 400), timestamp: 0.1, bounds: screen)
        XCTAssertEqual(next?.point.x ?? .nan, 500, accuracy: 1e-6)
        XCTAssertEqual(next?.point.y ?? .nan, 400, accuracy: 1e-6)
    }

    func testMedianRemovesIsolatedSpike() throws {
        var parameters = GazeParameters()
        parameters.medianWindow = 5
        var engine = GazeEngine(parameters: parameters)
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        var maxDeviation: CGFloat = 0
        for i in 0..<30 {
            let spike = (i == 15 || i == 16) ? 600.0 : 0.0   // clignement mal filtré : 2 images fausses
            let e = try XCTUnwrap(engine.process(raw: CGPoint(x: 500 + spike, y: 500), timestamp: Double(i) / 30, bounds: screen))
            if i > 5 { maxDeviation = max(maxDeviation, abs(e.smoothed.x - 500)) }
        }
        XCTAssertLessThan(maxDeviation, 1, "deux images aberrantes sur cinq ne doivent pas faire bouger le point")
    }

    func testRawSpreadMeasuresNoise() throws {
        var engine = GazeEngine()
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        XCTAssertNil(engine.rawSpread)
        for i in 0..<30 {
            _ = engine.process(raw: CGPoint(x: i.isMultiple(of: 2) ? 480 : 520, y: 500), timestamp: Double(i) / 30, bounds: screen)
        }
        XCTAssertEqual(try XCTUnwrap(engine.rawSpread), 20, accuracy: 1e-6)
    }
}

final class StableGazeFilterTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Bruit qui dérive (corrélé d'une image à l'autre), comme celui d'une webcam.
    private func wanderingNoise(count: Int, sigma: Double, seed: UInt64) -> [CGPoint] {
        var g = SeededGenerator(state: seed)
        var x = 0.0, y = 0.0
        let k = 0.85, s = sigma * (1 - k * k).squareRoot()
        func gauss() -> Double {
            let u = max(Double.random(in: 0...1, using: &g), 1e-12), v = Double.random(in: 0...1, using: &g)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        return (0..<count).map { _ in
            x = k * x + s * gauss()
            y = k * y + s * gauss()
            return CGPoint(x: x, y: y)
        }
    }

    func testConstantInputIsUnchanged() {
        var f = StableGazeFilter()
        for _ in 0..<50 { XCTAssertEqual(f.add(CGPoint(x: 300, y: 200)), CGPoint(x: 300, y: 200)) }
        XCTAssertEqual(f.jumpCount, 0)
    }

    func testWanderingNoiseAtRestBarelyMovesThePoint() {
        // Sur 10 tirages de bruit : au plus 2 avec un saut visible (> 40 pt d'une image à l'autre).
        var runsWithVisibleJump = 0
        var totalJumps = 0
        for seed in 1...10 {
            var f = StableGazeFilter()
            let noise = wanderingNoise(count: 150, sigma: 100, seed: UInt64(seed) * 7919)
            var outputs: [CGPoint] = []
            for n in noise { outputs.append(f.add(CGPoint(x: 600 + n.x, y: 400 + n.y))) }
            let settled = Array(outputs.suffix(100))
            let maxStep = zip(settled.dropFirst(), settled).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            if maxStep > 40 { runsWithVisibleJump += 1 }
            totalJumps += f.jumpCount
            let rawSpread = noise.suffix(100).map { hypot($0.x, $0.y) }.max() ?? 0
            XCTAssertGreaterThan(rawSpread, 120, "le bruit de test doit être fort")
        }
        XCTAssertLessThanOrEqual(runsWithVisibleJump, 2)
        XCTAssertLessThanOrEqual(totalJumps, 4)
    }

    func testRealJumpIsFollowedQuickly() {
        var f = StableGazeFilter()
        for _ in 0..<30 { _ = f.add(CGPoint(x: 300, y: 300)) }
        var framesToArrive: Int?
        for i in 0..<20 {
            let p = f.add(CGPoint(x: 900, y: 500))
            if framesToArrive == nil, hypot(p.x - 900, p.y - 500) < 50 { framesToArrive = i + 1 }
        }
        XCTAssertEqual(f.jumpCount, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(framesToArrive), 6, "moins de 0,2 s à 30 i/s")
    }

    func testIsolatedSpikeIsIgnored() {
        var f = StableGazeFilter()
        for _ in 0..<30 { _ = f.add(CGPoint(x: 300, y: 300)) }
        let p = f.add(CGPoint(x: 900, y: 300))
        XCTAssertLessThan(abs(p.x - 300), 25)
        for _ in 0..<5 { _ = f.add(CGPoint(x: 300, y: 300)) }
        XCTAssertEqual(f.jumpCount, 0)
    }

    func testMemoryLetsTheFixationFollowASlowDrift() {
        var f = StableGazeFilter()
        f.memory = 30
        var last = CGPoint.zero
        for i in 0..<120 { last = f.add(CGPoint(x: 300 + Double(i), y: 300)) }   // 1 pt par image
        XCTAssertEqual(last.x, 300 + 119 - 14.5, accuracy: 1)                    // moyenne des 30 dernières
    }

    func testNonFiniteIsIgnored() {
        var f = StableGazeFilter()
        _ = f.add(CGPoint(x: 10, y: 10))
        XCTAssertEqual(f.add(CGPoint(x: CGFloat.nan, y: 0)), CGPoint(x: 10, y: 10))
    }
}
