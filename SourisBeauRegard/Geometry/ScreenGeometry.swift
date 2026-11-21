import AppKit

/// Accès aux écrans (AppKit), avec conversion vers Quartz par `CoordinateSpaces`.
@MainActor
enum ScreenGeometry {
    /// Hauteur de l'écran principal (celui de la barre des menus), référence des conversions.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func quartzFrame(of screen: NSScreen) -> CGRect {
        CoordinateSpaces.appKitRectToQuartz(screen.frame, primaryScreenHeight: primaryScreenHeight)
    }

    /// Écran sous le pointeur, à défaut l'écran principal.
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
    }

    /// Écran dont le cadre Quartz est `frame`, à défaut l'écran principal.
    static func screen(matchingQuartzFrame frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { quartzFrame(of: $0) == frame } ?? NSScreen.screens.first
    }
}
