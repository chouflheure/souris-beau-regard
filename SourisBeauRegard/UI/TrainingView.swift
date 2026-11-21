import AppKit
import SwiftUI

/// Présente l'exercice d'entraînement en plein écran (pointeur visible : on clique à la souris).
@MainActor
final class TrainingWindowController {
    private var window: CalibrationWindow?

    func present(_ session: TrainingSession, on screen: NSScreen) {
        close()
        let window = CalibrationWindow(contentRect: screen.frame, styleMask: [.borderless],
                                       backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TrainingView(session: session))
        window.setFrame(screen.frame, display: true)
        window.onCancel = { [weak session] in session?.cancel() }
        window.onMouseDown = { [weak session] location in session?.click(at: location) }
        window.onKey = { [weak session] event in
            guard let session else { return false }
            switch event.keyCode {
            case 49: // Espace
                if session.stage == .intro { session.begin() }
                if case .result = session.stage { session.close() }
                if case .failed = session.stage { session.close() }
                return true
            case 36, 76: // Entrée
                if case .result = session.stage { session.close() }
                if case .failed = session.stage { session.close() }
                return true
            case 53: // Échap
                session.cancel()
                return true
            default:
                return false
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func close() {
        guard let window else { return }
        window.orderOut(nil)
        window.close()
        self.window = nil
    }
}

struct TrainingView: View {
    let session: TrainingSession

    var body: some View {
        ZStack {
            Color(white: 0.08)

            switch session.stage {
            case .intro:
                message(title: "Entraînement",
                        lines: ["Des cibles vont apparaître une à une sur tout l'écran.",
                                "Regardez chaque cible, puis cliquez dessus avec la souris en continuant à la regarder.",
                                "Chaque clic apprend au modèle où vous regardiez. Bougez un peu sur votre chaise de temps en temps :",
                                "le modèle apprendra aussi à suivre ces déplacements.",
                                "Espace pour commencer · Échap pour annuler"])
            case .running:
                if let feedback = session.lastFeedback {
                    FeedbackMark(feedback: feedback)
                }
                if let t = session.currentTarget {
                    TargetMark(radius: session.targetRadius)
                        .position(t)
                }
                VStack {
                    Spacer()
                    Text(progressText)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 28)
                }
            case .computing:
                message(title: "Apprentissage…", lines: ["Choix du meilleur modèle avec les nouvelles mesures."])
            case .result(let before, let after, let kept):
                message(title: "Entraînement terminé",
                        lines: ["\(kept) cible(s) mesurée(s).",
                                before.map { "Écart moyen pendant l'exercice (ancien modèle) : \(Int($0.rounded())) pt" } ?? "",
                                after.map { "Erreur estimée du nouveau modèle (validation croisée) : \(Int($0.rounded())) pt" } ?? "",
                                "Les mesures sont gardées et s'ajoutent à chaque nouvel entraînement.",
                                "Entrée pour fermer"])
            case .failed(let reason):
                message(title: "Entraînement impossible", lines: [reason, "Entrée pour fermer"])
            }
        }
        .ignoresSafeArea()
    }

    private var progressText: String {
        var text = "Cible \(min(session.index + 1, session.count))/\(session.count)"
        if let e = session.meanError { text += " · écart moyen \(Int(e.rounded())) pt" }
        if session.unmeasured > 0 { text += " · \(session.unmeasured) sans mesure (visage mal vu ?)" }
        return text
    }

    private func message(title: String, lines: [String]) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.largeTitle.bold())
            ForEach(Array(lines.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
                Text(line).font(.title3).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: 860)
    }
}

/// Cible à cliquer, qui pulse légèrement pour attirer le regard.
private struct TargetMark: View {
    let radius: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 1 + 0.12 * sin(t * 6)
            ZStack {
                Circle().stroke(Color.orange, lineWidth: 3)
                    .frame(width: radius * 2 * pulse, height: radius * 2 * pulse)
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Retour du clic précédent : où était la cible, où le modèle pensait que l'on regardait.
private struct FeedbackMark: View {
    let feedback: TrainingSession.Feedback

    var body: some View {
        Canvas { context, _ in
            let t = feedback.target
            context.stroke(Path(ellipseIn: CGRect(x: t.x - 10, y: t.y - 10, width: 20, height: 20)),
                           with: .color(.white.opacity(0.3)), lineWidth: 1)
            guard let e = feedback.estimate else { return }
            var line = Path()
            line.move(to: t)
            line.addLine(to: e)
            context.stroke(line, with: .color(.white.opacity(0.3)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: e.x - 5, y: e.y - 5, width: 10, height: 10)),
                         with: .color(.red.opacity(0.7)))
            if let error = feedback.error {
                context.draw(Text("\(Int(error.rounded())) pt").font(.caption).foregroundStyle(Color.white.opacity(0.6)),
                             at: CGPoint(x: e.x, y: e.y + 16))
            }
        }
        .allowsHitTesting(false)
    }
}
