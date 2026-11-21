import AppKit
import SwiftUI

/// Fenêtre plein écran sans bordure qui accepte le clavier (Espace, Échap, R, Entrée).
final class CalibrationWindow: NSWindow {
    var onKey: (@MainActor (NSEvent) -> Bool)?
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
                                    "Suivez des yeux chaque point jusqu'à ce qu'il disparaisse : 9 points, puis 5 de vérification.",
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
                case .fitting:
                    message(title: "Calcul…", lines: [])
                case .result(let result):
                    resultView(result)
                case .failed(let reason):
                    message(title: "Calibration impossible",
                            lines: [reason, "R pour recommencer · Échap pour fermer"])
                }
            }
        }
    }

    private var progressText: String {
        let phase = session.stage == .validating ? "Vérification" : "Calibration"
        return "\(phase) \(session.pointIndex + 1)/\(session.pointCount) · mesures : \(session.currentSampleCount)"
    }

    @ViewBuilder
    private func resultView(_ result: ValidationResult?) -> some View {
        if let result {
            let missing = result.pointErrors.filter { $0 == nil }.count
            message(title: "Erreur moyenne : \(Int(result.meanError.rounded())) points",
                    lines: ["Erreur maximale : \(Int(result.maxError.rounded())) points"
                                + (missing > 0 ? " · \(missing) point(s) sans mesure" : ""),
                            result.meanError < 150
                                ? "Objectif atteint (moins de 150 points)."
                                : "Au-dessus de l'objectif de 150 points : améliorez l'éclairage et recommencez.",
                            "Entrée pour garder cette calibration · R pour recommencer · Échap pour annuler"])
        } else {
            message(title: "Validation sans mesure",
                    lines: ["Aucun point de vérification n'a pu être mesuré.",
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
