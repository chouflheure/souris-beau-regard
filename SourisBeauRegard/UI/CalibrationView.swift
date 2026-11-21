import AppKit
import SwiftUI

/// Fenêtre plein écran sans bordure qui accepte le clavier (Espace, Échap, R, Entrée).
final class CalibrationWindow: NSWindow {
    var onKey: (@MainActor (NSEvent) -> Bool)?
    var onCancel: (@MainActor () -> Void)?
    /// Clic de souris, coordonnées de la vue (origine haut-gauche).
    var onMouseDown: (@MainActor (CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let onMouseDown else { return super.mouseDown(with: event) }
        let p = event.locationInWindow
        onMouseDown(CGPoint(x: p.x, y: frame.height - p.y))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Couvre tout l'écran, barre des menus et encoche comprises.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Présente une `CalibrationSession` en plein écran sombre sur un écran donné.
@MainActor
final class CalibrationWindowController {
    private var window: CalibrationWindow?

    func present(_ session: CalibrationSession, on screen: NSScreen) {
        close()
        let window = CalibrationWindow(contentRect: screen.frame, styleMask: [.borderless],
                                       backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CalibrationView(session: session))
        window.setFrame(screen.frame, display: true)
        window.onCancel = { [weak session] in session?.cancel() }
        window.onKey = { [weak session] event in
            guard let session else { return false }
            switch event.keyCode {
            case 49: // Espace
                if session.stage == .intro { session.begin(); return true }
                if case .poseIntro = session.stage { session.proceed(); return true }
                if case .result = session.stage { session.accept(); return true }
                return true
            case 36, 76: // Entrée
                if case .result = session.stage { session.accept() }
                return true
            case 15: // R
                if !session.isCollecting { session.restart() }
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
        NSCursor.hide()
        self.window = window
    }

    func close() {
        guard let window else { return }
        NSCursor.unhide()
        window.orderOut(nil)
        window.close()
        self.window = nil
    }
}

struct CalibrationView: View {
    let session: CalibrationSession

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.08).ignoresSafeArea()

                switch session.stage {
                case .intro:
                    message(title: "Calibration",
                            lines: ["Asseyez-vous à 50–70 cm, visage bien éclairé, et gardez la tête immobile.",
                                    "Suivez des yeux chaque point jusqu'à ce qu'il disparaisse : \(session.plan.gridSize * session.plan.gridSize) points"
                                        + (session.plan.poses.isEmpty ? "" : ", puis 9 points dans \(session.plan.poses.count) autre(s) position(s) de la tête")
                                        + ", puis 5 de vérification.",
                                    "Espace pour commencer · Échap pour annuler"])
                case .calibrating, .validating:
                    if let p = session.currentPoint {
                        ShrinkingDot(start: session.pointStart, duration: session.plan.pointDuration,
                                     color: session.stage == .validating ? .cyan : .white)
                            .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                    }
                    VStack {
                        Spacer()
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.bottom, 24)
                    }
                case .poseIntro(let instruction):
                    message(title: "Changement de position",
                            lines: [instruction,
                                    "Puis regardez à nouveau chaque point.",
                                    "Espace pour continuer · Échap pour annuler"])
                case .fitting:
                    message(title: "Calcul…", lines: [])
                case .result(let result):
                    if let result {
                        ValidationPlot(result: result, screenFrame: session.screenFrame)
                    }
                    resultView(result)
                case .failed(let reason):
                    message(title: "Calibration impossible",
                            lines: [reason, "R pour recommencer · Échap pour fermer"])
                }
            }
        }
        // Sans cela, sur un écran à encoche, la zone de dessin exclut le haut de l'écran
        // et les points s'affichent plus bas que les cibles enregistrées.
        .ignoresSafeArea()
    }

    private var progressText: String {
        let phase = session.stage == .validating ? "Vérification" : "Calibration"
        let pose = session.poseLabel.isEmpty ? "" : "\(session.poseLabel) · "
        return "\(pose)\(phase) \(session.pointIndex + 1)/\(session.pointCount) · mesures : \(session.currentSampleCount)"
    }

    @ViewBuilder
    private func resultView(_ result: ValidationResult?) -> some View {
        let modelLine = session.model.map { model in
            "Modèle : \(model.kind.label), λ = \(String(format: "%.2g", model.lambda))"
                + (model.crossValidationError.map { String(format: " · validation croisée %.0f pt", $0) } ?? "")
        } ?? ""
        if let result {
            let missing = result.pointErrors.filter { $0 == nil }.count
            message(title: "Erreur moyenne : \(Int(result.meanError.rounded())) points",
                    lines: ["Maximale : \(Int(result.maxError.rounded())) pt · en x : \(Int(result.meanErrorX.rounded())) pt · en y : \(Int(result.meanErrorY.rounded())) pt"
                                + (missing > 0 ? " · \(missing) point(s) sans mesure" : ""),
                            modelLine,
                            result.meanError < 150
                                ? "Objectif atteint (moins de 150 points)."
                                : "Au-dessus de l'objectif de 150 points. Cercles cyan : cibles ; points rouges : estimations.",
                            "Entrée pour garder cette calibration · R pour recommencer · Échap pour annuler"])
        } else {
            message(title: "Validation sans mesure",
                    lines: ["Aucun point de vérification n'a pu être mesuré.", modelLine,
                            "Entrée pour garder quand même · R pour recommencer · Échap pour annuler"])
        }
    }

    private func message(title: String, lines: [String]) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.largeTitle.bold())
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.title3).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: 820)
    }
}

/// Point qui rétrécit pendant `duration` pour retenir le regard.
private struct ShrinkingDot: View {
    let start: Double
    let duration: Double
    let color: Color

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let t = min(max(elapsed / duration, 0), 1)
            let radius = 4 + 20 * (1 - t)
            ZStack {
                Circle().fill(color.opacity(0.35)).frame(width: radius * 2, height: radius * 2)
                Circle().fill(color).frame(width: 6, height: 6)
            }
        }
    }
}

/// Cibles de validation (cercles cyan) et estimations du modèle (points rouges), reliées par un trait.
private struct ValidationPlot: View {
    let result: ValidationResult
    let screenFrame: CGRect

    var body: some View {
        Canvas { context, _ in
            for (target, estimate) in zip(result.targets, result.estimates) {
                guard let target, let estimate else { continue }
                let t = CGPoint(x: target.x - screenFrame.minX, y: target.y - screenFrame.minY)
                let e = CGPoint(x: estimate.x - screenFrame.minX, y: estimate.y - screenFrame.minY)
                var line = Path()
                line.move(to: t)
                line.addLine(to: e)
                context.stroke(line, with: .color(.white.opacity(0.4)), lineWidth: 1)
                context.stroke(Path(ellipseIn: CGRect(x: t.x - 12, y: t.y - 12, width: 24, height: 24)),
                               with: .color(.cyan), lineWidth: 2)
                context.fill(Path(ellipseIn: CGRect(x: e.x - 6, y: e.y - 6, width: 12, height: 12)),
                             with: .color(.red))
            }
        }
        .allowsHitTesting(false)
    }
}
