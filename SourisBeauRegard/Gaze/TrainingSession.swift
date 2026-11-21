import CoreGraphics
import Foundation
import Observation

/// Exercice d'entraînement : des cibles apparaissent une à une, on les clique à la souris en les
/// regardant. Chaque clic donne des mesures (prises juste avant) associées à un point connu.
/// Logique pure, testée.
enum TrainingPlan {
    /// Marge des cibles par rapport aux bords, en fraction de l'écran.
    static let margin: CGFloat = 0.05

    /// `count` cibles couvrant tout l'écran : grille `columns × rows`, une position tirée au hasard
    /// dans chaque case, cases mélangées ; la grille est reparcourue si `count` la dépasse.
    /// Coordonnées normalisées (0…1, origine haut-gauche).
    static func targets<G: RandomNumberGenerator>(count: Int, columns: Int = 6, rows: Int = 4,
                                                  using generator: inout G) -> [CGPoint] {
        guard count > 0, columns > 0, rows > 0 else { return [] }
        let span = 1 - 2 * margin
        let cw = span / CGFloat(columns), ch = span / CGFloat(rows)
        var cells: [(Int, Int)] = []
        var result: [CGPoint] = []
        while result.count < count {
            if cells.isEmpty {
                cells = (0..<rows).flatMap { r in (0..<columns).map { c in (c, r) } }.shuffled(using: &generator)
            }
            let (c, r) = cells.removeLast()
            let x = margin + (CGFloat(c) + CGFloat.random(in: 0.15...0.85, using: &generator)) * cw
            let y = margin + (CGFloat(r) + CGFloat.random(in: 0.15...0.85, using: &generator)) * ch
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }

    /// Le clic touche-t-il la cible ?
    static func hits(_ click: CGPoint, target: CGPoint, radius: CGFloat) -> Bool {
        hypot(click.x - target.x, click.y - target.y) <= radius
    }
}

/// Déroulé de l'exercice. Sur le fil principal.
@MainActor
@Observable
final class TrainingSession {
    enum Stage: Equatable {
        case intro
        case running
        case computing
        case result(before: Double?, after: Double?, kept: Int)
        case failed(String)
    }

    struct Feedback: Equatable {
        /// Cible et regard estimé au moment du clic, coordonnées de la vue (= écran, origine haut-gauche).
        var target: CGPoint
        var estimate: CGPoint?
        var error: Double?
    }

    private(set) var stage: Stage = .intro
    /// Cible affichée, coordonnées de la vue.
    private(set) var currentTarget: CGPoint?
    private(set) var index = 0
    private(set) var lastFeedback: Feedback?
    private(set) var missedClicks = 0
    private(set) var unmeasured = 0

    let screenFrame: CGRect
    let count: Int
    /// Rayon de la cible dessinée et de la zone cliquable (points).
    let targetRadius: CGFloat = 22
    let hitRadius: CGFloat = 45

    /// Mesures valides de la fenêtre donnée (temps absolus `systemUptime`).
    @ObservationIgnored var featuresProvider: (@MainActor (ClosedRange<Double>) -> [GazeFeatures])?
    /// Prédiction du modèle actuel (décalage compris), coordonnées Quartz.
    @ObservationIgnored var predictor: (@MainActor (GazeFeatures) -> CGPoint)?
    /// Fin : groupes de mesures (un par clic) à apprendre, ou `nil` si annulé.
    @ObservationIgnored var onFinish: (@MainActor (_ groups: [[CalibrationSample]]?, _ beforeError: Double?) -> Void)?
    /// Fermeture de la fenêtre une fois le résultat affiché.
    @ObservationIgnored var onClose: (@MainActor () -> Void)?

    @ObservationIgnored private var targets: [CGPoint] = []
    @ObservationIgnored private var groups: [[CalibrationSample]] = []
    @ObservationIgnored private var errors: [Double] = []
    @ObservationIgnored private var lookBack: ClosedRange<Double>

    init(screenFrame: CGRect, count: Int, lookBack: ClosedRange<Double>) {
        self.screenFrame = screenFrame
        self.count = count
        self.lookBack = lookBack
    }

    var meanError: Double? { errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count) }

    func begin() {
        guard stage == .intro else { return }
        var generator = SystemRandomNumberGenerator()
        targets = TrainingPlan.targets(count: count, using: &generator).map {
            CGPoint(x: $0.x * screenFrame.width, y: $0.y * screenFrame.height)
        }
        groups = []
        errors = []
        index = 0
        stage = .running
        currentTarget = targets.first
    }

    /// Clic dans la fenêtre, coordonnées de la vue.
    func click(at location: CGPoint) {
        guard stage == .running, let target = currentTarget else { return }
        guard TrainingPlan.hits(location, target: target, radius: hitRadius) else {
            missedClicks += 1
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let window = (now - lookBack.upperBound)...(now - lookBack.lowerBound)
        let features = featuresProvider?(window) ?? []
        let targetQuartz = CGPoint(x: screenFrame.minX + target.x, y: screenFrame.minY + target.y)
        if features.count >= 3 {
            groups.append(features.map { CalibrationSample(features: $0, target: targetQuartz) })
            var estimate: CGPoint?
            var error: Double?
            if let predictor {
                let predictions = features.map { predictor($0) }
                let p = CGPoint(x: Stats.median(predictions.map { Double($0.x) }),
                                y: Stats.median(predictions.map { Double($0.y) }))
                estimate = CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY)
                let e = Double(hypot(p.x - targetQuartz.x, p.y - targetQuartz.y))
                errors.append(e)
                error = e
            }
            lastFeedback = Feedback(target: target, estimate: estimate, error: error)
        } else {
            unmeasured += 1
            lastFeedback = Feedback(target: target, estimate: nil, error: nil)
        }
        index += 1
        if index < targets.count {
            currentTarget = targets[index]
        } else {
            currentTarget = nil
            stage = .computing
            onFinish?(groups, meanError)
        }
    }

    /// Résultat de l'apprentissage (appelé par l'état central).
    func showResult(after: Double?) {
        stage = .result(before: meanError, after: after, kept: groups.count)
    }

    func showFailure(_ message: String) {
        stage = .failed(message)
    }

    func cancel() {
        if stage == .running || stage == .intro { onFinish?(nil, nil) }
        onClose?()
    }

    func close() {
        onClose?()
    }
}
