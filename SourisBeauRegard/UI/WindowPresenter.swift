import AppKit
import SwiftUI

/// Ouvre et ferme des fenêtres AppKit qui hébergent des vues SwiftUI.
///
/// Une app de barre des menus (`LSUIElement`) n'est jamais active d'elle-même : on gère donc
/// les fenêtres à la main pour pouvoir les ouvrir au lancement et les mettre au premier plan.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    func show<Content: View>(id: String, title: String, size: CGSize,
                             content: Content, onClose: (() -> Void)? = nil) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[id] = window
        closeHandlers[id] = onClose
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        closeHandlers.removeValue(forKey: id)?()
    }
}
