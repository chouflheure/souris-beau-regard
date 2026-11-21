import Accelerate
import CoreGraphics

/// Régression ridge des mesures vers un point écran (x, y).
///
/// - Les entrées sont centrées-réduites (moyenne et écart-type de la calibration).
/// - Les `polynomialCount` premières entrées passent par un polynôme de degré 2
///   (termes linéaires, carrés et produits croisés), les suivantes restent linéaires.
/// - Les colonnes développées sont recentrées : l'ordonnée à l'origine n'est donc pas pénalisée.
/// - Produits matriciels avec Accelerate (vDSP), système (ΦᵀΦ + λI) w = Φᵀy résolu par Cholesky.
struct RidgeRegression: Codable, Sendable, Equatable {
    var lambda: Double
    var polynomialCount: Int
    var inputMeans: [Double]
    var inputStds: [Double]
    var expandedMeans: [Double]
    var weightsX: [Double]
    var weightsY: [Double]
    var interceptX: Double
    var interceptY: Double

    enum FitError: Error, Equatable {
        case notEnoughSamples
        case inconsistentInput
        case notPositiveDefinite
    }

    // MARK: - Développement polynomial

    static func expand(_ z: [Double], polynomialCount p: Int) -> [Double] {
        var out = Array(z[0..<p])
        for i in 0..<p {
            for j in i..<p { out.append(z[i] * z[j]) }
        }
        out.append(contentsOf: z[p...])
        return out
    }

    static func expandedCount(inputCount n: Int, polynomialCount p: Int) -> Int {
        p + p * (p + 1) / 2 + (n - p)
    }

    // MARK: - Apprentissage

    static func fit(inputs: [[Double]], targets: [CGPoint], lambda: Double,
                    polynomialCount: Int) throws -> RidgeRegression {
        let n = inputs.count
        guard n >= 2, n == targets.count else { throw FitError.notEnoughSamples }
        let inputCount = inputs[0].count
        guard inputCount >= polynomialCount, polynomialCount >= 0,
              inputs.allSatisfy({ $0.count == inputCount })
        else { throw FitError.inconsistentInput }

        // Centrage-réduction des entrées.
        var means = [Double](repeating: 0, count: inputCount)
        for row in inputs { for k in 0..<inputCount { means[k] += row[k] } }
        means = means.map { $0 / Double(n) }
        var stds = [Double](repeating: 0, count: inputCount)
        for row in inputs { for k in 0..<inputCount { stds[k] += (row[k] - means[k]) * (row[k] - means[k]) } }
        stds = stds.map { v in
            let s = (v / Double(n)).squareRoot()
            return s > 1e-9 ? s : 1   // colonne constante : elle deviendra nulle après centrage
        }

        // Matrice développée Φ (n × d), lignes contiguës.
        let d = expandedCount(inputCount: inputCount, polynomialCount: polynomialCount)
        var phi = [Double](repeating: 0, count: n * d)
        for (r, row) in inputs.enumerated() {
            let z = (0..<inputCount).map { (row[$0] - means[$0]) / stds[$0] }
            let e = expand(z, polynomialCount: polynomialCount)
            for c in 0..<d { phi[r * d + c] = e[c] }
        }
        var expandedMeans = [Double](repeating: 0, count: d)
        for r in 0..<n { for c in 0..<d { expandedMeans[c] += phi[r * d + c] } }
        expandedMeans = expandedMeans.map { $0 / Double(n) }
        for r in 0..<n { for c in 0..<d { phi[r * d + c] -= expandedMeans[c] } }

        // Cibles centrées (n × 2).
        let meanX = targets.map { Double($0.x) }.reduce(0, +) / Double(n)
        let meanY = targets.map { Double($0.y) }.reduce(0, +) / Double(n)
        var y = [Double](repeating: 0, count: n * 2)
        for (r, t) in targets.enumerated() {
            y[r * 2] = Double(t.x) - meanX
            y[r * 2 + 1] = Double(t.y) - meanY
        }

        // Φᵀ (d × n), G = ΦᵀΦ (d × d), b = Φᵀy (d × 2).
        var phiT = [Double](repeating: 0, count: d * n)
        vDSP_mtransD(phi, 1, &phiT, 1, vDSP_Length(d), vDSP_Length(n))
        var gram = [Double](repeating: 0, count: d * d)
        vDSP_mmulD(phiT, 1, phi, 1, &gram, 1, vDSP_Length(d), vDSP_Length(d), vDSP_Length(n))
        var rhs = [Double](repeating: 0, count: d * 2)
        vDSP_mmulD(phiT, 1, y, 1, &rhs, 1, vDSP_Length(d), vDSP_Length(2), vDSP_Length(n))
        for i in 0..<d { gram[i * d + i] += lambda }

        guard let chol = cholesky(gram, size: d) else { throw FitError.notPositiveDefinite }
        let wx = choleskySolve(chol, size: d, rhs: (0..<d).map { rhs[$0 * 2] })
        let wy = choleskySolve(chol, size: d, rhs: (0..<d).map { rhs[$0 * 2 + 1] })

        return RidgeRegression(lambda: lambda, polynomialCount: polynomialCount,
                               inputMeans: means, inputStds: stds, expandedMeans: expandedMeans,
                               weightsX: wx, weightsY: wy, interceptX: meanX, interceptY: meanY)
    }

    // MARK: - Prédiction

    func predict(_ input: [Double]) -> CGPoint {
        guard input.count == inputMeans.count else { return CGPoint(x: interceptX, y: interceptY) }
        let z = (0..<input.count).map { (input[$0] - inputMeans[$0]) / inputStds[$0] }
        let e = Self.expand(z, polynomialCount: polynomialCount)
        var x = interceptX, y = interceptY
        for c in 0..<e.count {
            let v = e[c] - expandedMeans[c]
            x += v * weightsX[c]
            y += v * weightsY[c]
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Cholesky (matrice d × d, ligne par ligne)

    /// Décomposition A = L Lᵀ ; renvoie L (triangulaire inférieure) ou `nil` si A n'est pas définie positive.
    static func cholesky(_ a: [Double], size n: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    guard sum > 1e-12 else { return nil }
                    l[i * n + i] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        return l
    }

    /// Résout L Lᵀ x = b.
    static func choleskySolve(_ l: [Double], size n: Int, rhs b: [Double]) -> [Double] {
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= l[i * n + k] * z[k] }
            z[i] = sum / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = z[i]
            for k in (i + 1)..<n { sum -= l[k * n + i] * x[k] }
            x[i] = sum / l[i * n + i]
        }
        return x
    }
}
