/// Détection des clignements, y compris leurs images de début et de fin.
///
/// Un clignement dure plusieurs images : la paupière descend puis remonte. Sur les images à moitié
/// fermées, l'ouverture reste au-dessus d'un seuil fixe, mais les mesures de pupille sont fausses
/// (et le modèle, qui a appris qu'une paupière basse veut dire « regard vers le bas », fait plonger
/// le point). On compare donc l'ouverture à **l'ouverture habituelle de la personne** (médiane des
/// dernières images yeux ouverts), et on écarte aussi quelques images après le clignement.
/// Logique pure, testée.
struct BlinkDetector: Sendable, Equatable {
    /// En dessous de cette fraction de l'ouverture habituelle : clignement (ou paupière qui tombe).
    var relativeThreshold = 0.6
    /// Seuil absolu, en plus (yeux mal vus).
    var absoluteThreshold = 0.15
    /// Images écartées après la dernière image de clignement (la paupière finit de remonter).
    var holdFrames = 3
    /// Nombre d'images yeux ouverts gardées pour l'ouverture habituelle.
    var baselineLength = 60

    private(set) var baseline: [Double] = []
    private var hold = 0

    /// Ouverture habituelle (médiane des dernières images yeux ouverts).
    var typicalOpenness: Double? {
        baseline.isEmpty ? nil : Stats.median(baseline)
    }

    /// Ajoute l'ouverture d'une image (la plus petite des deux yeux) ; renvoie `true` si l'image
    /// doit être écartée.
    mutating func isBlink(openness: Double) -> Bool {
        guard openness.isFinite else { return true }
        let closing = openness < absoluteThreshold
            || (typicalOpenness.map { openness < relativeThreshold * $0 } ?? false)
        // L'ouverture habituelle suit aussi les paupières un peu baissées (regard vers le bas
        // prolongé) ; un clignement, bref, ne déplace pas la médiane.
        if openness >= absoluteThreshold {
            baseline.append(openness)
            if baseline.count > baselineLength { baseline.removeFirst(baseline.count - baselineLength) }
        }
        if closing {
            hold = holdFrames
            return true
        }
        if hold > 0 {
            hold -= 1
            return true
        }
        return false
    }

    mutating func reset() {
        baseline = []
        hold = 0
    }
}
