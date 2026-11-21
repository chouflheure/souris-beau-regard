import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class TrainingTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testTargetsCoverWholeScreenInsideMargins() {
        var g = SeededGenerator(state: 1)
        let targets = TrainingPlan.targets(count: 48, columns: 6, rows: 4, using: &g)
        XCTAssertEqual(targets.count, 48)
        XCTAssertTrue(targets.allSatisfy { $0.x > 0.05 && $0.x < 0.95 && $0.y > 0.05 && $0.y < 0.95 })
        // Chaque case de la grille est visitée deux fois.
        var visits: [String: Int] = [:]
        for t in targets {
            let c = Int((t.x - 0.05) / (0.9 / 6)), r = Int((t.y - 0.05) / (0.9 / 4))
            visits["\(c),\(r)", default: 0] += 1
        }
        XCTAssertEqual(visits.count, 24)
        XCTAssertTrue(visits.values.allSatisfy { $0 == 2 })
        XCTAssertTrue(TrainingPlan.targets(count: 0, using: &g).isEmpty)
    }

    func testHits() {
        XCTAssertTrue(TrainingPlan.hits(CGPoint(x: 10, y: 10), target: CGPoint(x: 40, y: 50), radius: 50))
        XCTAssertFalse(TrainingPlan.hits(CGPoint(x: 10, y: 10), target: CGPoint(x: 100, y: 100), radius: 50))
    }

    // MARK: - Réapprentissage

    private func features(_ nx: Double, _ ny: Double, _ g: inout SeededGenerator) -> GazeFeatures {
        let n = { (g: inout SeededGenerator) in Double.random(in: -0.002...0.002, using: &g) }
        let mx = 0.3 + 0.4 * nx, my = 0.1 - 0.1 * ny
        return GazeFeatures(leftPupilX: mx + n(&g), leftPupilY: my + n(&g), rightPupilX: mx + n(&g), rightPupilY: my + n(&g),
                            aperture: 0.3 + n(&g), yaw: n(&g), pitch: n(&g), roll: n(&g),
                            faceCenterX: 0.5 + n(&g), faceCenterY: 0.5 + n(&g), faceSize: 0.2 + n(&g))
    }

    func testTrainingGroupsCorrectASystematicBias() throws {
        var g = SeededGenerator(state: 11)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var calibration: [CalibrationSample] = []
        for p in CalibrationPlan.calibrationGrid {
            let target = CoordinateSpaces.normalizedToQuartz(p, screenFrameQuartz: screen)
            for _ in 0..<15 { calibration.append(CalibrationSample(features: features(p.x, p.y, &g), target: target)) }
        }
        var model = try CalibrationModel.fit(samples: calibration, screenFrame: screen, pupilLocator: .image,
                                             kind: .binocular, lambda: 1)

        // Pendant l'exercice, tout est décalé : le vrai point regardé est 70 pt plus bas que ce que
        // les mesures « disent » (tête déplacée depuis la calibration, par exemple).
        var groups: [[CalibrationSample]] = []
        var targets = SeededGenerator(state: 3)
        for t in TrainingPlan.targets(count: 30, using: &targets) {
            let target = CGPoint(x: t.x * 1440, y: t.y * 900 + 70)
            groups.append((0..<8).map { _ in CalibrationSample(features: features(t.x, t.y, &g), target: target) })
        }
        func meanError(_ m: CalibrationModel) -> Double {
            groups.map { group -> Double in
                let e = ModelSelection.medianPrediction(group, kind: m.kind, regression: m.regression)
                let c = m.correction(at: e)
                let p = CGPoint(x: e.x + c.x, y: e.y + c.y)
                return Double(hypot(p.x - group[0].target.x, p.y - group[0].target.y))
            }.reduce(0, +) / Double(groups.count)
        }
        let before = meanError(model)
        XCTAssertGreaterThan(before, 50)

        model.addTraining(groups)
        XCTAssertEqual(model.implicitSamples?.count, 240)
        XCTAssertEqual(model.implicitEventCount, 30)
        XCTAssertEqual(model.recentEvents?.count, 30)
        XCTAssertEqual(model.biasPoints?.count, 30)
        try model.relearn(kind: nil, lambda: nil)
        XCTAssertNotNil(model.autoKind)
        XCTAssertNotNil(model.crossValidationError)
        XCTAssertLessThan(meanError(model), before / 2)
    }
}
