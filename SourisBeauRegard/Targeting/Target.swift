import CoreGraphics

/// Un élément cliquable trouvé par l'accessibilité. Coordonnées Quartz (points écran, origine
/// haut-gauche de l'écran principal). Valeur pure : aucune référence à l'API d'accessibilité.
struct TargetCandidate: Sendable, Equatable, Identifiable {
    /// Identité stable d'une image à l'autre : app, rôle et cadre arrondi.
    var id: String
    var frame: CGRect
    var role: String
    var title: String?
    var pid: Int32

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    static func makeID(pid: Int32, role: String, frame: CGRect) -> String {
        "\(pid)|\(role)|\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
    }
}

/// Géométrie du ciblage. Logique pure, testée.
enum TargetGeometry {
    /// Grille n × n de points d'échantillonnage dans le carré de rayon `radius` autour de `center`.
    static func samplePoints(around center: CGPoint, radius: CGFloat, gridSize n: Int) -> [CGPoint] {
        guard n > 1 else { return [center] }
        let step = 2 * radius / CGFloat(n - 1)
        var points: [CGPoint] = []
        points.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                points.append(CGPoint(x: center.x - radius + CGFloat(i) * step,
                                      y: center.y - radius + CGFloat(j) * step))
            }
        }
        // Du centre vers l'extérieur : si le temps manque, les points proches du regard passent d'abord.
        return points.sorted { hypot($0.x - center.x, $0.y - center.y) < hypot($1.x - center.x, $1.y - center.y) }
    }

    /// Cible dont le centre est le plus proche du regard, dans le rayon d'accroche.
    static func nearest(_ candidates: [TargetCandidate], to point: CGPoint, radius: CGFloat) -> TargetCandidate? {
        candidates
            .map { ($0, hypot($0.center.x - point.x, $0.center.y - point.y)) }
            .filter { $0.1 <= radius || $0.0.frame.contains(point) }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Case de cache pour un point d'échantillonnage.
    static func cacheCell(for point: CGPoint, cellSize: CGFloat) -> String {
        "\(Int((point.x / cellSize).rounded(.down))),\(Int((point.y / cellSize).rounded(.down)))"
    }
}

/// Choix de la cible avec hystérésis : on ne change de cible (ou on ne la perd) que si la nouvelle
/// situation dure au moins `hysteresis` secondes. Évite le clignotement entre deux boutons voisins.
struct TargetSelector: Sendable, Equatable {
    var hysteresis: Double = 0.15
    var radius: CGFloat = 120
    /// Marge d'accroche (points) : tant que le regard reste dans la cible élargie de cette marge,
    /// on la garde, même si un voisin est plus proche ou si la recherche l'a manquée cette fois-ci.
    var stickiness: CGFloat = 40

    private(set) var current: TargetCandidate?
    /// Situation en attente de confirmation : `.some(nil)` signifie « plus de cible ».
    private var pending: TargetCandidate??
    private var pendingSince: Double = 0

    init(hysteresis: Double = 0.15, radius: CGFloat = 120, stickiness: CGFloat = 40) {
        self.hysteresis = hysteresis
        self.radius = radius
        self.stickiness = stickiness
    }

    /// - Parameter immediate: le regard vient de changer d'endroit (saut confirmé par la stabilisation) :
    ///   on change de cible sans attendre l'hystérésis, déjà « payée » par la confirmation du saut.
    @discardableResult
    mutating func update(candidates: [TargetCandidate], gaze: CGPoint, time: Double,
                         immediate: Bool = false) -> TargetCandidate? {
        if let current, current.frame.insetBy(dx: -stickiness, dy: -stickiness).contains(gaze) {
            // Le regard est toujours sur la cible (élargie) : on la garde, cadre rafraîchi si retrouvée.
            self.current = candidates.first { $0.id == current.id } ?? current
            pending = nil
            return self.current
        }
        let best = TargetGeometry.nearest(candidates, to: gaze, radius: radius)
        if immediate, let best {
            current = best
            pending = nil
            return current
        }
        if best?.id == current?.id {
            current = best          // même cible : on garde, cadre rafraîchi
            pending = nil
            return current
        }
        if let pending, pending?.id == best?.id {
            if time - pendingSince >= hysteresis {
                current = best
                self.pending = nil
            }
        } else {
            pending = .some(best)
            pendingSince = time
        }
        return current
    }

    mutating func reset() {
        current = nil
        pending = nil
    }
}

/// Historique court des cibles : au moment de l'appui, on prend celle d'environ 120 ms avant,
/// car le regard part souvent vers l'élément suivant quand on appuie (utilisé à l'étape 4).
struct TargetHistory: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var time: Double
        var target: TargetCandidate?
    }

    var maxAge: Double = 1.0
    private(set) var entries: [Entry] = []

    mutating func record(_ target: TargetCandidate?, at time: Double) {
        if entries.last?.target?.id != target?.id || entries.isEmpty {
            entries.append(Entry(time: time, target: target))
        }
        // On garde toujours au moins l'entrée en vigueur au début de la fenêtre.
        while entries.count > 1, entries[1].time < time - maxAge {
            entries.removeFirst()
        }
    }

    /// Cible en vigueur à l'instant `time`.
    func target(at time: Double) -> TargetCandidate? {
        entries.last(where: { $0.time <= time })?.target
    }
}
