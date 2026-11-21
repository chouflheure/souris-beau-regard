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
                ModelControls()
            }
            Section("Lissage") {
                LabeledContent("Coupure minimale (Hz)") {
                    Slider(value: $settings.smoothingMinCutoff, in: 0.05...3)
                    Text(String(format: "%.2f", settings.smoothingMinCutoff)).monospacedDigit()
                }
                LabeledContent("Réactivité (bêta)") {
                    Slider(value: $settings.smoothingBeta, in: 0...0.02)
                    Text(String(format: "%.4f", settings.smoothingBeta)).monospacedDigit()
                }
                LabeledContent("Fixation : durée (s)") {
                    Slider(value: $settings.fixationDuration, in: 0.05...0.6)
                    Text(String(format: "%.2f", settings.fixationDuration)).monospacedDigit()
                }
                LabeledContent("Fixation : dispersion (pt)") {
                    Slider(value: $settings.fixationDispersion, in: 20...300)
                    Text(String(format: "%.0f", settings.fixationDispersion)).monospacedDigit()
                }
                Stepper("Filtre médian : \(settings.medianWindow) image(s)",
                        value: $settings.medianWindow, in: 1...15)
                Button("Valeurs par défaut") { settings.resetSmoothing() }
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

/// Choix du modèle de régression, de λ et de la grille de calibration (réglages et débogage).
struct ModelControls: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        VStack(alignment: .leading, spacing: 6) {
            Picker("Modèle", selection: $settings.modelChoice) {
                Text("Automatique (validation croisée)").tag(GazeModelKind?.none)
                ForEach(GazeModelKind.allCases) { Text($0.label).tag(GazeModelKind?.some($0)) }
            }
            Toggle("λ automatique", isOn: $settings.lambdaAuto)
            if !settings.lambdaAuto {
                LabeledContent("λ (ridge)") {
                    Slider(value: $settings.ridgeLambdaLog10, in: -2...3)
                    Text(String(format: "%.2g", settings.ridgeLambda)).monospacedDigit()
                }
            }
            Picker("Points de calibration", selection: $settings.calibrationGridSize) {
                Text("9 (3 × 3)").tag(3)
                Text("16 (4 × 4)").tag(4)
                Text("25 (5 × 5)").tag(5)
            }
            Toggle("Apprendre aussi sur les points de validation", isOn: $settings.trainOnValidation)
        }
    }
}
