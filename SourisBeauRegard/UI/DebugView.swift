import SwiftUI

/// Fenêtre de débogage : image caméra, repères du visage, valeurs mesurées, images par seconde.
struct DebugView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        HStack(alignment: .top, spacing: 0) {
            CameraPreview(image: appState.previewImage,
                          frame: appState.lastFrame,
                          mirrored: settings.mirrorPreview)
                .frame(minWidth: 560, minHeight: 360)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Aperçu en miroir", isOn: $settings.mirrorPreview)
                    Legend()
                    WarningsSection()
                    GazeSection()
                    MeasurementsSection()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 380)
        }
        .frame(minWidth: 940, minHeight: 480)
    }
}

// MARK: - Aperçu

private struct CameraPreview: View {
    let image: CGImage?
    let frame: FaceFrame?
    let mirrored: Bool

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Démarrage de la caméra…").foregroundStyle(.secondary)
                }
            }
            if let frame, let face = frame.face {
                FaceOverlay(face: face, imageSize: frame.imageSize, mirrored: mirrored)
            }
        }
    }
}

/// Dessine la boîte du visage, les repères et les pupilles par-dessus l'image.
private struct FaceOverlay: View {
    let face: FaceMeasurement
    let imageSize: CGSize
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            let imageRect = CoordinateSpaces.aspectFitRect(contentSize: imageSize,
                                                           in: CGRect(origin: .zero, size: size))
            func toView(_ p: CGPoint) -> CGPoint {
                CoordinateSpaces.visionToView(p, imageRect: imageRect, mirrored: mirrored)
            }

            let box = CoordinateSpaces.visionRectToView(face.boundingBox, imageRect: imageRect, mirrored: mirrored)
            context.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(.green), lineWidth: 1.5)

            for eye in [face.leftEye, face.rightEye].compactMap({ $0 }) {
                let eyeBox = CoordinateSpaces.visionRectToView(eye.box, imageRect: imageRect, mirrored: mirrored)
                context.stroke(Path(eyeBox), with: .color(.cyan.opacity(0.8)), lineWidth: 1)
            }

            for region in face.regions {
                let points = region.points.map(toView)
                if region.kind == .pupil {
                    for p in points {
                        let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                        context.fill(Path(ellipseIn: dot), with: .color(.red))
                    }
                } else {
                    var path = Path()
                    path.addLines(points)
                    if region.closed { path.closeSubpath() }
                    context.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 1)
                }
            }

            // Pupille trouvée dans l'image (zone sombre) : croix magenta.
            for eye in [face.leftEye, face.rightEye].compactMap({ $0 }) {
                guard let p = eye.imagePupil.map(toView) else { continue }
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 5, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 5, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 5)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 5))
                context.stroke(cross, with: .color(.pink), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Panneau latéral

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            Label("Pupille Vision", systemImage: "circle.fill").foregroundStyle(.red)
            Label("Pupille image", systemImage: "plus").foregroundStyle(.pink)
            Label("Œil", systemImage: "square").foregroundStyle(.cyan)
        }
        .font(.caption)
    }
}

private struct GazeSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        let features = appState.lastFeatures
        GroupBox("Regard") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Pupille", selection: $settings.pupilLocator) {
                    ForEach(PupilLocatorKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.pupilLocator == .image {
                    LabeledContent("Part sombre") {
                        Slider(value: $settings.pupilDarkFraction, in: 0.03...0.4)
                        Text(String(format: "%.2f", settings.pupilDarkFraction)).monospacedDigit()
                    }
                    .font(.callout)
                }

                ValueRow("Pupille G (x, y)", features.map { String(format: "%.3f, %.3f", $0.leftPupilX, $0.leftPupilY) } ?? "—")
                ValueRow("Pupille D (x, y)", features.map { String(format: "%.3f, %.3f", $0.rightPupilX, $0.rightPupilY) } ?? "—")
                ValueRow("Écart Vision / image G", pupilGap(appState.lastFrame?.face?.leftEye))
                ValueRow("Écart Vision / image D", pupilGap(appState.lastFrame?.face?.rightEye))

                Divider()

                if let calibration = appState.calibration {
                    ValueRow("Erreur de validation",
                             calibration.validation.map { String(format: "moy. %.0f pt · max %.0f pt", $0.meanError, $0.maxError) } ?? "—")
                    ValueRow("… en x / en y",
                             calibration.validation.map { String(format: "%.0f pt / %.0f pt", $0.meanErrorX, $0.meanErrorY) } ?? "—")
                    ValueRow("Validation croisée",
                             calibration.crossValidationError.map { String(format: "%.0f pt", $0) } ?? "—")
                    ValueRow("Modèle", "\(calibration.kind.label), λ = \(String(format: "%.2g", calibration.lambda))")
                    ValueRow("Mesures", "\(calibration.trainingSamples.count)"
                             + (calibration.trainedOnValidation ? " (calibration + validation)" : ""))
                    if calibration.pupilLocator != settings.pupilLocator {
                        Label("Calibré avec « \(calibration.pupilLocator.label) » : recalibrez après avoir changé de méthode.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Pas encore calibré.").foregroundStyle(.secondary).font(.callout)
                }
                ModelControls()
                    .font(.callout)
                Button("Afficher les données de calibration") { appState.revealCalibrationFile() }
                    .controlSize(.small)

                if let reason = appState.gazeLossReason {
                    Label(reason, systemImage: "eye.slash")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ValueRow("Bruit du regard (1 s)", appState.gazeSpread.map { String(format: "%.0f pt", $0) } ?? "—")
                ValueRow("Relances caméra", "\(appState.cameraRestarts)")
                if let gaze = appState.gaze {
                    ValueRow("Regard brut", String(format: "%.0f, %.0f", gaze.raw.x, gaze.raw.y))
                    ValueRow("Regard lissé", String(format: "%.0f, %.0f", gaze.smoothed.x, gaze.smoothed.y))
                    ValueRow("Fixation", gaze.fixation.map { String(format: "%.0f, %.0f", $0.x, $0.y) } ?? "non")
                }
                if let error = appState.calibrationSaveError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }

                HStack {
                    Button("Calibrer…") { appState.startCalibration() }
                    if appState.calibration != nil {
                        Button("Effacer la calibration", role: .destructive) { appState.deleteCalibration() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Distance entre les deux pupilles trouvées, en fraction de la largeur de l'œil.
    private func pupilGap(_ eye: EyeMeasurement?) -> String {
        guard let eye, let a = eye.visionPupil, let b = eye.imagePupil, eye.box.width > 0 else { return "—" }
        return String(format: "%.2f largeur d'œil", hypot(a.x - b.x, a.y - b.y) / eye.box.width)
    }
}

private struct WarningsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let warnings = FaceQuality.warnings(for: appState.lastFrame,
                                            fps: appState.fps,
                                            thresholds: appState.settings.qualityThresholds)
        VStack(alignment: .leading, spacing: 6) {
            if let error = appState.cameraError {
                Label(error, systemImage: "video.slash")
                    .foregroundStyle(.red)
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if warnings.isEmpty, appState.cameraError == nil, appState.lastFrame?.face != nil {
                Label("Visage bien suivi", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.callout)
    }
}

private struct MeasurementsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let frame = appState.lastFrame
        let face = frame?.face
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Caméra") {
                VStack(alignment: .leading, spacing: 4) {
                    if let info = appState.cameraInfo {
                        ValueRow("Appareil", info.name)
                        ValueRow("Résolution", "\(info.width) × \(info.height)")
                        ValueRow("Cadence demandée", String(format: "%.0f i/s", info.frameRate))
                    }
                    ValueRow("Images par seconde", String(format: "%.1f", appState.fps))
                    ValueRow("Analyse Vision", frame.map { String(format: "%.1f ms", $0.processingTime * 1000) } ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Visage") {
                VStack(alignment: .leading, spacing: 4) {
                    ValueRow("Confiance visage", face.map { String(format: "%.2f", $0.faceConfidence) } ?? "—")
                    ValueRow("Confiance repères", face.map { String(format: "%.2f", $0.landmarksConfidence) } ?? "—")
                    ValueRow("Lacet", face.map { degrees($0.yaw) } ?? "—")
                    ValueRow("Tangage", face.map { degrees($0.pitch) } ?? "—")
                    ValueRow("Roulis", face.map { degrees($0.roll) } ?? "—")
                    ValueRow("Centre", face.map { String(format: "%.3f, %.3f", $0.boundingBox.midX, $0.boundingBox.midY) } ?? "—")
                    ValueRow("Taille", face.map { String(format: "%.3f", $0.boundingBox.width) } ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Yeux") {
                VStack(alignment: .leading, spacing: 4) {
                    ValueRow("Ouverture gauche (image)", face?.leftEye.map { String(format: "%.2f", $0.openness) } ?? "—")
                    ValueRow("Ouverture droite (image)", face?.rightEye.map { String(format: "%.2f", $0.openness) } ?? "—")
                    ValueRow("Pupille Vision gauche", pupilText(face?.leftEye))
                    ValueRow("Pupille Vision droite", pupilText(face?.rightEye))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func degrees(_ radians: Double) -> String {
        String(format: "%.1f°", radians * 180 / .pi)
    }

    /// Position de la pupille dans la boîte de l'œil (0…1). Calcul complet à l'étape 2.
    private func pupilText(_ eye: EyeMeasurement?) -> String {
        guard let eye, let p = eye.visionPupil, eye.box.width > 0, eye.box.height > 0 else { return "—" }
        let x = (p.x - eye.box.minX) / eye.box.width
        let y = (p.y - eye.box.minY) / eye.box.height
        return String(format: "%.2f, %.2f", x, y)
    }
}

private struct ValueRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
