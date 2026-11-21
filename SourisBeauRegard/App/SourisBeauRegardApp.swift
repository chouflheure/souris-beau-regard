import AppKit
import SwiftUI

@main
struct SourisBeauRegardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Souris beau regard", systemImage: "eye") {
            MenuContent()
                .environment(AppState.shared)
        }

        Settings {
            SettingsView()
                .environment(AppState.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.applicationDidFinishLaunching()
    }
}

/// Contenu du menu de la barre des menus.
struct MenuContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Text(appState.isCameraRunning ? "Caméra : active" : "Caméra : arrêtée")
        if let validation = appState.calibration?.validation {
            Text("Calibration : erreur moyenne \(Int(validation.meanError.rounded())) pt")
        } else if appState.calibration == nil {
            Text("Pas encore calibré")
        }

        Divider()

        Button("Calibrer…") { appState.startCalibration() }
        Button(appState.recenterShortcutAvailable ? "Recentrer (\(GlobalHotKeys.recenter.label))" : "Recentrer") {
            appState.recenter()
        }
        .disabled(!appState.isTrackingActive)
        Toggle("Suivre le regard", isOn: $settings.trackingEnabled)
            .disabled(appState.calibration == nil)
        Toggle("Afficher le point de regard", isOn: $settings.showGazePoint)

        Divider()

        Button("Autorisations…") { appState.showOnboarding() }
        Button("Fenêtre de débogage…") { appState.showDebugWindow() }
        SettingsLink { Text("Réglages…") }
            .keyboardShortcut(",")

        Divider()

        Button("Quitter Souris beau regard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
