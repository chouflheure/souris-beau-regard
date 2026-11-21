import AppKit
import SwiftUI

/// Réglages. Version minimale pour l'étape 1 ; la fenêtre complète (touche, rayon d'accroche,
/// lissage, choix du PupilLocator…) arrive à l'étape 5.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Avertissements de qualité (fenêtre de débogage)") {
                LabeledContent("Confiance minimale") {
                    Slider(value: $settings.minFaceConfidence, in: 0...1)
                    Text(String(format: "%.2f", settings.minFaceConfidence)).monospacedDigit()
                }
                LabeledContent("Ouverture des yeux minimale") {
                    Slider(value: $settings.minEyeOpenness, in: 0...0.6)
                    Text(String(format: "%.2f", settings.minEyeOpenness)).monospacedDigit()
                }
                LabeledContent("Images par seconde minimales") {
                    Slider(value: $settings.minFPS, in: 10...30, step: 1)
                    Text(String(format: "%.0f", settings.minFPS)).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear { NSApp.activate() }
    }
}
