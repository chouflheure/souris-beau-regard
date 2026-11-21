import Foundation

/// Filtre One Euro (Casiez, Roussel, Vogel 2012) : passe-bas dont la fréquence de coupure
/// augmente avec la vitesse. Peu de tremblement à l'arrêt, peu de retard sur les grands mouvements.
struct OneEuroFilter: Sendable, Equatable {
    /// Coupure minimale (Hz) : plus bas = plus lisse à l'arrêt, mais plus de retard.
    var minCutoff: Double
    /// Gain de vitesse : plus haut = moins de retard sur les mouvements rapides.
    var beta: Double
    /// Coupure du filtre de la dérivée (Hz).
    var derivativeCutoff: Double

    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * max(cutoff, 1e-6))
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: Double, timestamp: Double) -> Double {
        guard let previous = lastValue, let previousTime = lastTime else {
            lastValue = value
            lastTime = timestamp
            lastDerivative = 0
            return value
        }
        // Horodatage identique ou en arrière : on garde un pas minimal plutôt que diviser par zéro.
        let dt = max(timestamp - previousTime, 1e-3)
        let derivative = (value - previous) / dt
        let aD = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let smoothedDerivative = aD * derivative + (1 - aD) * lastDerivative
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * previous

        lastValue = result
        lastDerivative = smoothedDerivative
        lastTime = timestamp
        return result
    }

    mutating func reset() {
        lastValue = nil
        lastTime = nil
        lastDerivative = 0
    }
}
