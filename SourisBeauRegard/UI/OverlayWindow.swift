import AppKit
import Observation
import SwiftUI

/// Ce que dessine la fenêtre de surlignage, en coordonnées de la vue (origine haut-gauche de l'écran).
@MainActor
@Observable
final class OverlayModel {
    var gazePoint: CGPoint?
    var isFixating = false
}

/// Fenêtre transparente au-dessus de tout, sur tous les bureaux et en plein écran,
/// qui ne reçoit jamais la souris. Dessine le point de regard (et la cible à l'étape 3).
@MainActor
final class OverlayWindowController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var screenFrameQuartz: CGRect = .zero

    var isVisible: Bool { panel?.isVisible ?? false }

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
    func update(gaze point: CGPoint?, isFixating: Bool) {
        model.gazePoint = point.map {
            CGPoint(x: $0.x - screenFrameQuartz.minX, y: $0.y - screenFrameQuartz.minY)
        }
        model.isFixating = isFixating
    }
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        Canvas { context, _ in
            guard let p = model.gazePoint else { return }
            let r: CGFloat = 14
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            let color: Color = model.isFixating ? .green : .orange
            context.fill(circle, with: .color(color.opacity(0.25)))
            context.stroke(circle, with: .color(color.opacity(0.9)), lineWidth: 2)
            let dot = Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            context.fill(dot, with: .color(color))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
