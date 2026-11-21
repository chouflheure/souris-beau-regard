import CoreGraphics
import XCTest
@testable import SourisBeauRegard

final class RidgeRegressionTests: XCTestCase {

    /// Générateur pseudo-aléatoire déterministe (LCG) pour des tests reproductibles.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func randomInputs(count: Int, dimension: Int) -> [[Double]] {
        var g = SeededGenerator(state: 42)
        return (0..<count).map { _ in (0..<dimension).map { _ in Double.random(in: -1...1, using: &g) } }
    }

    func testExpandCountsAndTerms() {
        let e = RidgeRegression.expand([1, 2, 3], polynomialCount: 2)
        // x1, x2, x1², x1x2, x2², x3
        XCTAssertEqual(e, [1, 2, 1, 2, 4, 3])
        XCTAssertEqual(RidgeRegression.expandedCount(inputCount: 10, polynomialCount: 4), 20)
        XCTAssertEqual(RidgeRegression.expand(Array(repeating: 1, count: 10), polynomialCount: 4).count, 20)
    }

    func testRecoversLinearFunction() throws {
        let inputs = randomInputs(count: 200, dimension: 3)
        let targets = inputs.map { CGPoint(x: 100 + 300 * $0[0] - 50 * $0[2], y: -20 + 80 * $0[1]) }
        let model = try RidgeRegression.fit(inputs: inputs, targets: targets, lambda: 1e-6, polynomialCount: 0)
        for (input, target) in zip(inputs.prefix(20), targets) {
            let p = model.predict(input)
            XCTAssertEqual(p.x, target.x, accuracy: 1e-3)
            XCTAssertEqual(p.y, target.y, accuracy: 1e-3)
        }
    }

    func testRecoversQuadraticFunctionOfPupils() throws {
        let inputs = randomInputs(count: 300, dimension: 10)
        let targets = inputs.map { v in
            CGPoint(x: 800 + 400 * v[0] + 120 * v[0] * v[0] - 60 * v[1] * v[2] + 30 * v[5],
                    y: 500 + 300 * v[1] + 90 * v[3] * v[3] + 20 * v[7])
        }
        let model = try RidgeRegression.fit(inputs: inputs, targets: targets, lambda: 1e-6, polynomialCount: 4)
        let test = randomInputs(count: 5, dimension: 10)
        for v in test {
            let expected = CGPoint(x: 800 + 400 * v[0] + 120 * v[0] * v[0] - 60 * v[1] * v[2] + 30 * v[5],
                                   y: 500 + 300 * v[1] + 90 * v[3] * v[3] + 20 * v[7])
            let p = model.predict(v)
            XCTAssertEqual(p.x, expected.x, accuracy: 0.1)
            XCTAssertEqual(p.y, expected.y, accuracy: 0.1)
        }
    }

    func testLargeLambdaShrinksTowardMean() throws {
        let inputs = randomInputs(count: 100, dimension: 2)
        let targets = inputs.map { CGPoint(x: 1000 * $0[0], y: 1000 * $0[1]) }
        let model = try RidgeRegression.fit(inputs: inputs, targets: targets, lambda: 1e9, polynomialCount: 0)
        let meanX = targets.map(\.x).reduce(0, +) / CGFloat(targets.count)
        XCTAssertEqual(model.predict([1, 1]).x, meanX, accuracy: 1)
    }

    func testConstantColumnDoesNotBreakFit() throws {
        var inputs = randomInputs(count: 50, dimension: 3)
        for i in inputs.indices { inputs[i][1] = 7 }
        let targets = inputs.map { CGPoint(x: 10 * $0[0], y: 5 * $0[2]) }
        let model = try RidgeRegression.fit(inputs: inputs, targets: targets, lambda: 1e-3, polynomialCount: 0)
        XCTAssertEqual(model.predict([0.5, 7, -0.5]).x, 5, accuracy: 0.01)
        XCTAssertEqual(model.predict([0.5, 7, -0.5]).y, -2.5, accuracy: 0.01)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try RidgeRegression.fit(inputs: [[1]], targets: [.zero], lambda: 1, polynomialCount: 0))
        XCTAssertThrowsError(try RidgeRegression.fit(inputs: [[1, 2], [1]], targets: [.zero, .zero], lambda: 1, polynomialCount: 0))
        XCTAssertThrowsError(try RidgeRegression.fit(inputs: [[1, 2], [3, 4]], targets: [.zero], lambda: 1, polynomialCount: 0))
    }

    func testCholeskySolve() throws {
        // A = [[4, 2], [2, 3]], b = [2, 1] → x = [0.5, 0]
        let l = try XCTUnwrap(RidgeRegression.cholesky([4, 2, 2, 3], size: 2))
        let x = RidgeRegression.choleskySolve(l, size: 2, rhs: [2, 1])
        XCTAssertEqual(x[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(x[1], 0, accuracy: 1e-12)
        XCTAssertNil(RidgeRegression.cholesky([1, 2, 2, 1], size: 2))
    }

    // MARK: - Modèle de calibration et sauvegarde

    private func features(_ v: [Double]) -> GazeFeatures {
        GazeFeatures(leftPupilX: v[0], leftPupilY: v[1], rightPupilX: v[2], rightPupilY: v[3], aperture: v[10],
                     yaw: v[4], pitch: v[5], roll: v[6], faceCenterX: v[7], faceCenterY: v[8], faceSize: v[9])
    }

    /// Mesures simulées : les pupilles bougent linéairement avec le point regardé, plus du bruit.
    private func simulatedSamples(points: [CGPoint], perPoint: Int) -> [CalibrationSample] {
        var g = SeededGenerator(state: 7)
        var out: [CalibrationSample] = []
        for p in points {
            for _ in 0..<perPoint {
                let nx = Double(p.x) / 1440, ny = Double(p.y) / 900
                let noise = { Double.random(in: -0.002...0.002, using: &g) }
                let v = [0.3 + 0.4 * nx + noise(), 0.6 - 0.3 * ny + noise(),
                         0.3 + 0.4 * nx + noise(), 0.6 - 0.3 * ny + noise(),
                         noise(), noise(), noise(), 0.5 + noise(), 0.5 + noise(), 0.3 + noise(),
                         0.35 - 0.05 * ny + noise()]
                out.append(CalibrationSample(features: features(v), target: p))
            }
        }
        return out
    }

    func testCalibrationModelFitValidateAndRefit() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = CalibrationPlan.calibrationGrid.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
        for kind in GazeModelKind.allCases {
            var model = try CalibrationModel.fit(samples: simulatedSamples(points: grid, perPoint: 20),
                                                 screenFrame: screen, pupilLocator: .image, kind: kind, lambda: 1)
            let validationTargets = CalibrationPlan.validationPoints.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
            let groups = validationTargets.map { simulatedSamples(points: [$0], perPoint: 10) }
            try model.finalize(validation: groups, trainOnValidation: false)
            let result = try XCTUnwrap(model.validation)
            XCTAssertLessThan(result.meanError, 40, "\(kind)")
            XCTAssertEqual(result.pointErrors.count, 5)
            XCTAssertEqual(result.estimates.count, 5)
            XCTAssertLessThanOrEqual(result.meanErrorX, result.meanError + 1e-9)

            try model.refit(kind: kind, lambda: 1e6)
            XCTAssertEqual(model.regression.lambda, 1e6)
            XCTAssertGreaterThan(try XCTUnwrap(model.validation).meanError, result.meanError)
        }
    }

    func testAutomaticChoiceAndTrainingOnValidation() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = CalibrationPlan.calibrationGrid.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
        var model = try CalibrationModel.fit(samples: simulatedSamples(points: grid, perPoint: 15),
                                             screenFrame: screen, pupilLocator: .image, kind: nil, lambda: nil)
        XCTAssertNotNil(model.autoKind)
        XCTAssertNotNil(model.autoLambda)
        XCTAssertNotNil(model.crossValidationError)
        let validationTargets = CalibrationPlan.validationPoints.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
        let groups = validationTargets.map { simulatedSamples(points: [$0], perPoint: 10) }
        try model.finalize(validation: groups, trainOnValidation: true)
        XCTAssertTrue(model.trainedOnValidation)
        XCTAssertEqual(model.trainingSamples.count, 9 * 15 + 5 * 10)
        XCTAssertEqual(model.kind, model.autoKind)
        XCTAssertEqual(model.lambda, model.autoLambda)
        XCTAssertLessThan(try XCTUnwrap(model.validation).meanError, 40)
    }

    func testCalibrationNeedsEnoughSamples() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let samples = simulatedSamples(points: [CGPoint(x: 100, y: 100)], perPoint: 50)
        XCTAssertThrowsError(try CalibrationModel.fit(samples: samples, screenFrame: screen, pupilLocator: .vision,
                                                      kind: .binocular, lambda: 1)) {
            XCTAssertEqual($0 as? CalibrationModel.FitError, .notEnoughSamples)
        }
    }

    func testOffsetIsAddedToPrediction() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = CalibrationPlan.calibrationGrid.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
        let samples = simulatedSamples(points: grid, perPoint: 10)
        var model = try CalibrationModel.fit(samples: samples, screenFrame: screen, pupilLocator: .image,
                                             kind: .full, lambda: 1)
        let f = samples[0].features
        let before = model.predict(f)
        model.offset = CGPoint(x: 12, y: -8)
        XCTAssertEqual(model.predict(f).x, before.x + 12, accuracy: 1e-9)
        XCTAssertEqual(model.predict(f).y, before.y - 8, accuracy: 1e-9)
        XCTAssertEqual(model.predictUncorrected(f), before)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CalibrationStore(url: dir.appendingPathComponent("sub/calibration.json"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(store.load())

        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let grid = CalibrationPlan.calibrationGrid.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
        var model = try CalibrationModel.fit(samples: simulatedSamples(points: grid, perPoint: 5),
                                             screenFrame: screen, pupilLocator: .vision, kind: .binocularHead, lambda: 2,
                                             date: Date(timeIntervalSince1970: 1_700_000_000))
        try model.finalize(validation: [simulatedSamples(points: [grid[4]], perPoint: 3), []], trainOnValidation: false)
        model.offset = CGPoint(x: 3, y: 4)
        try store.save(model)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, model)
        XCTAssertNil(loaded.validation?.pointErrors[1] ?? nil)
        let f = model.calibrationSamples[0].features
        XCTAssertEqual(loaded.predict(f), model.predict(f))

        // Une calibration d'une version antérieure n'est pas rechargée.
        model.version = 1
        try store.save(model)
        XCTAssertNil(store.load())

        store.delete()
        XCTAssertNil(store.load())
    }

    // MARK: - Choix du modèle

    func testModelInputs() {
        let f = features([0.2, 0.3, 0.4, 0.5, 1, 2, 3, 4, 5, 6, 0.7])
        XCTAssertEqual(GazeModelKind.binocular.inputs(f), [0.30000000000000004, 0.4, 0.7])
        XCTAssertEqual(GazeModelKind.binocularHead.inputs(f).count, 9)
        XCTAssertEqual(GazeModelKind.full.inputs(f), [0.2, 0.3, 0.4, 0.5, 0.7, 1, 2, 3, 4, 5, 6])
    }

    func testCrossValidationPrefersSimpleModelWhenHeadIsNoise() throws {
        // Les mesures de la tête ne sont que du bruit : le modèle complet sur-apprend.
        var g = SeededGenerator(state: 99)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var samples: [CalibrationSample] = []
        for p in CalibrationPlan.calibrationGrid.map({ CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }) {
            // La tête bouge un peu d'un point à l'autre, sans rapport avec le regard.
            let head = (0..<6).map { _ in Double.random(in: -1...1, using: &g) }
            for _ in 0..<15 {
                let nx = Double(p.x) / 1440, ny = Double(p.y) / 900
                let n = { Double.random(in: -0.01...0.01, using: &g) }
                let v = [0.3 + 0.4 * nx + n(), 0.1 - 0.1 * ny + n(), 0.3 + 0.4 * nx + n(), 0.1 - 0.1 * ny + n()]
                    + head.map { $0 + n() } + [0.3 + n()]
                samples.append(CalibrationSample(features: features(v), target: p))
            }
        }
        let best = try XCTUnwrap(ModelSelection.best(samples))
        XCTAssertEqual(best.kind, .binocular)
        let full = try XCTUnwrap(ModelSelection.crossValidationError(samples, kind: .full, lambda: 0.03))
        XCTAssertLessThan(best.error, full)
    }

    /// Avec plusieurs positions de tête à la calibration, le modèle « + tête » corrige un déplacement
    /// de la tête jamais vu ; le modèle sans la tête se trompe.
    func testHeadModelCompensatesHeadShiftWhenCalibratedInSeveralPoses() throws {
        var g = SeededGenerator(state: 5)
        func sample(_ p: CGPoint, headShift hx: Double) -> CalibrationSample {
            let n = { Double.random(in: -0.002...0.002, using: &g) }
            let headOnScreen = 720 + 4000 * hx           // 0,1 de décalage dans l'image ≈ 400 pt à l'écran
            let mx = 0.5 + 0.4 * (Double(p.x) - headOnScreen) / 1440
            let my = 0.1 - 0.1 * Double(p.y) / 900
            let v = [mx + n(), my + n(), mx + n(), my + n(), n(), n(), n(),
                     0.5 + hx + n() * 0.1, 0.5 + n() * 0.1, 0.2 + n() * 0.1, 0.3 + n()]
            return CalibrationSample(features: features(v), target: p)
        }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = CalibrationPlan.calibrationGrid.map { CoordinateSpaces.normalizedToQuartz($0, screenFrameQuartz: screen) }
        var training: [CalibrationSample] = []
        for hx in [0, -0.1, 0.1] { for p in grid { for _ in 0..<10 { training.append(sample(p, headShift: hx)) } } }

        func error(_ kind: GazeModelKind) throws -> Double {
            let regression = try kind.fit(training, lambda: 0.1)
            let targets = [CGPoint(x: 720, y: 450), CGPoint(x: 389, y: 252)]
            let errors = targets.map { t -> Double in
                let group = (0..<10).map { _ in sample(t, headShift: 0.05) }
                let e = ModelSelection.medianPrediction(group, kind: kind, regression: regression)
                return Double(hypot(e.x - t.x, e.y - t.y))
            }
            return errors.reduce(0, +) / Double(errors.count)
        }
        XCTAssertLessThan(try error(.binocularHead), 30)
        XCTAssertGreaterThan(try error(.binocular), 50)
    }

    func testGroupsKeepOrder() {
        let a = CalibrationSample(features: features(Array(repeating: 0, count: 11)), target: CGPoint(x: 1, y: 1))
        let b = CalibrationSample(features: features(Array(repeating: 0, count: 11)), target: CGPoint(x: 2, y: 2))
        let groups = ModelSelection.groups([a, b, a, a, b])
        XCTAssertEqual(groups.map(\.count), [3, 2])
        XCTAssertEqual(groups[0][0].target, CGPoint(x: 1, y: 1))
    }
}
