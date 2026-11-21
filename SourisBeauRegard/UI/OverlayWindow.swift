import AppKit
import Observation
import SwiftUI

/// État du point de regard affiché.
enum GazeDisplayStatus: Sendable, Equatable {
    /// Suivi normal (orange).
    case tracking
    /// Fixation en cours (vert).
    case fixating
    /// La prédiction tombe hors de l'écran (rouge, pointillé) : tête déplacée depuis la calibration ?
    case offScreen
    /// Visage ou yeux perdus, ou clignement (gris, pointillé, à la dernière position connue).
    case lost
}

/// Ce que dessine la fenêtre de surlignage, en coordonnées de la vue (origine haut-gauche de l'écran).
@MainActor
@Observable
final class OverlayModel {
    var gazePoint: CGPoint?
    var status: GazeDisplayStatus = .tracking
    /// Point à regarder pendant un recentrage (coordonnées de la vue).
    var recenterTarget: CGPoint?
}

/// Fenêtre transparente au-dessus de tout, sur tous les bureaux et en plein écran,
/// qui ne reçoit jamais la souris. Dessine le point de regard (et la cible à l'étape 3).
@MainActor
final class OverlayWindowController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var screenFrameQuartz: CGRect = .zero

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Écran sur lequel le panneau est affiché (cadre Quartz).
    var displayedScreenFrame: CGRect { screenFrameQuartz }

    func show(on screen: NSScreen) {
        let frame = screen.frame
        screenFrameQuartz = ScreenGeometry.quartzFrame(of: screen)
        if let panel {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        model.gazePoint = nil
    }

    /// `point` en coordonnées Quartz globales.
    /// `point` en coordonnées Quartz globales ; `nil` pour l'effacer.
    func showRecenterTarget(_ point: CGPoint?) {
        model.recenterTarget = point.map {
            CGPoint(x: $0.x - screenFrameQuartz.minX, y: $0.y - screenFrameQuartz.minY)
        }
    }

    func update(gaze point: CGPoint?, status: GazeDisplayStatus) {
        model.gazePoint = point.map {
            CGPoint(x: $0.x - screenFrameQuartz.minX, y: $0.y - screenFrameQuartz.minY)
        }
        model.status = status
    }
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        Canvas { context, _ in
            if let t = model.recenterTarget {
                let ring = Path(ellipseIn: CGRect(x: t.x - 20, y: t.y - 20, width: 40, height: 40))
                context.fill(ring, with: .color(.cyan.opacity(0.2)))
                context.stroke(ring, with: .color(.cyan), lineWidth: 3)
                context.fill(Path(ellipseIn: CGRect(x: t.x - 4, y: t.y - 4, width: 8, height: 8)), with: .color(.cyan))
                context.draw(Text("Regardez ce point").font(.headline).foregroundStyle(Color.cyan),
                             at: CGPoint(x: t.x, y: t.y + 40))
            }
            guard let p = model.gazePoint else { return }
            let r: CGFloat = 14
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            switch model.status {
            case .tracking, .fixating:
                let color: Color = model.status == .fixating ? .green : .orange
                context.fill(circle, with: .color(color.opacity(0.25)))
                context.stroke(circle, with: .color(color.opacity(0.9)), lineWidth: 2)
                let dot = Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                context.fill(dot, with: .color(color))
            case .offScreen, .lost:
                let color: Color = model.status == .offScreen ? .red : .gray
                context.stroke(circle, with: .color(color.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                let label = model.status == .offScreen ? "hors écran" : "regard perdu"
                context.draw(Text(label).font(.caption.bold()).foregroundStyle(color),
                             at: CGPoint(x: p.x, y: p.y + r + 10))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
