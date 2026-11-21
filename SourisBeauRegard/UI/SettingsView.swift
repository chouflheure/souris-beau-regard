import AppKit
import SwiftUI

/// Réglages. Version provisoire ; la fenêtre complète (touche, rayon d'accroche,
/// lissage, choix du PupilLocator…) arrive à l'étape 5.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Regard") {
                Toggle("Suivre le regard", isOn: $settings.trackingEnabled)
                Toggle("Afficher le point de regard", isOn: $settings.showGazePoint)
                Picker("Localisation de la pupille", selection: $settings.pupilLocator) {
                    ForEach(PupilLocatorKind.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Régularisation λ") {
                    Slider(value: $settings.ridgeLambdaLog10, in: -2...3)
                    Text(String(format: "%.2g", settings.ridgeLambda)).monospacedDigit()
                }
            }
            Section("Lissage") {
                LabeledContent("Coupure minimale (Hz)") {
                    Slider(value: $settings.smoothingMinCutoff, in: 0.05...5)
                    Text(String(format: "%.2f", settings.smoothingMinCutoff)).monospacedDigit()
                }
                LabeledContent("Réactivité (bêta)") {
                    Slider(value: $settings.smoothingBeta, in: 0...0.05)
                    Text(String(format: "%.3f", settings.smoothingBeta)).monospacedDigit()
                }
                LabeledContent("Fixation : durée (s)") {
                    Slider(value: $settings.fixationDuration, in: 0.05...0.6)
                    Text(String(format: "%.2f", settings.fixationDuration)).monospacedDigit()
                }
                LabeledContent("Fixation : dispersion (pt)") {
                    Slider(value: $settings.fixationDispersion, in: 20...250)
                    Text(String(format: "%.0f", settings.fixationDispersion)).monospacedDigit()
                }
            }
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
