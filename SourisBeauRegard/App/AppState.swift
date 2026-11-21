import AppKit
import Observation
import SwiftUI

/// État central de l'app, sur le fil principal.
///
/// Chaîne du regard, à chaque image : `CameraService` (file dédiée : Vision + pupilles)
/// → `GazeFeatures` → `CalibrationModel` (régression) → `GazeEngine` (One Euro + fixation)
/// → fenêtre de surlignage. Le ciblage (étape 3) et le clic (étape 4) se brancheront ici.
@MainActor
@Observable
final class AppState {
    /// Instance unique, créée au premier accès sur le fil principal.
    static let shared = AppState()

    let permissions = PermissionsManager()
    let settings = AppSettings()
    let camera = CameraService()
    private let windows = WindowPresenter()
    private let overlay = OverlayWindowController()
    private let calibrationWindow = CalibrationWindowController()
    private let store = CalibrationStore()

    // Derniers résultats de la caméra.
    private(set) var lastFrame: FaceFrame?
    private(set) var lastFeatures: GazeFeatures?
    private(set) var previewImage: CGImage?
    private(set) var fps: Double = 0
    private(set) var cameraInfo: CameraInfo?
    private(set) var cameraError: String?
    private(set) var isCameraRunning = false

    // Regard.
    private(set) var calibration: CalibrationModel?
    private(set) var calibrationSession: CalibrationSession?
    private(set) var gaze: GazeEstimate?
    private(set) var calibrationSaveError: String?

    private(set) var isDebugWindowOpen = false
    @ObservationIgnored private var isCameraStarting = false
    @ObservationIgnored private var engine = GazeEngine()
    @ObservationIgnored private var lastGazeUpdate: Double = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Vrai pendant les tests unitaires (l'app hôte ne doit alors rien ouvrir).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Délai sans visage après lequel le point de regard disparaît (s).
    private static let gazeTimeout = 0.5

    init() {
        camera.setHandler { [weak self] output in
            Task { @MainActor in self?.handle(output) }
        }
        settings.onGazeDisplayChange = { [weak self] in self?.gazeDisplayChanged() }
    }

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching() {
        guard !Self.isRunningTests else { return }
        permissions.refresh()
        calibration = store.load()
        if !permissions.allRequiredGranted || !settings.hasCompletedOnboarding {
            showOnboarding()
        }
        updateCameraState()
        updateOverlay()
    }

    // MARK: - Fenêtres

    func showOnboarding() {
        permissions.startPolling()
        windows.show(id: "onboarding", title: "Bienvenue dans Souris beau regard",
                     size: CGSize(width: 560, height: 480),
                     content: OnboardingView().environment(self)) { [weak self] in
            self?.permissions.stopPolling()
        }
    }

    func closeOnboarding() {
        settings.hasCompletedOnboarding = true
        windows.close(id: "onboarding")
    }

    func showDebugWindow() {
        isDebugWindowOpen = true
        updateCameraState()
        windows.show(id: "debug", title: "Débogage — Souris beau regard",
                     size: CGSize(width: 1040, height: 640),
                     content: DebugView().environment(self)) { [weak self] in
            self?.isDebugWindowOpen = false
            self?.previewImage = nil
            self?.updateCameraState()
        }
    }

    // MARK: - Suivi du regard

    /// Le regard est suivi et affiché : calibration présente, suivi activé, pas de calibration en cours.
    var isTrackingActive: Bool {
        settings.trackingEnabled && calibration != nil && calibrationSession == nil
    }

    /// Suivi activé ou point de regard affiché / masqué (depuis le menu ou les réglages).
    private func gazeDisplayChanged() {
        engine.reset()
        gaze = nil
        updateCameraState()
        updateOverlay()
    }

    private func updateOverlay() {
        guard !Self.isRunningTests else { return }
        if isTrackingActive, settings.showGazePoint, let calibration,
           let screen = ScreenGeometry.screen(matchingQuartzFrame: calibration.screenFrame) {
            if !overlay.isVisible { overlay.show(on: screen) }
        } else {
            overlay.hide()
        }
    }

    // MARK: - Calibration

    func startCalibration() {
        guard calibrationSession == nil, let screen = ScreenGeometry.screenUnderMouse() else { return }
        let session = CalibrationSession(screenFrame: ScreenGeometry.quartzFrame(of: screen),
                                         plan: settings.calibrationPlan,
                                         pupilLocator: settings.pupilLocator,
                                         lambda: settings.ridgeLambda)
        session.onFinish = { [weak self] model in self?.finishCalibration(model) }
        calibrationSession = session
        overlay.hide()
        updateCameraState()
        calibrationWindow.present(session, on: screen)
    }

    private func finishCalibration(_ model: CalibrationModel?) {
        calibrationWindow.close()
        calibrationSession = nil
        if let model {
            calibration = model
            engine.reset()
            gaze = nil
            saveCalibration(immediately: true)
        }
        updateCameraState()
        updateOverlay()
    }

    func deleteCalibration() {
        calibration = nil
        gaze = nil
        store.delete()
        updateCameraState()
        updateOverlay()
    }

    private func saveCalibration(immediately: Bool) {
        saveTask?.cancel()
        guard let model = calibration else { return }
        let store = self.store
        saveTask = Task { [weak self] in
            if !immediately {
                // Regroupe les écritures pendant qu'on fait glisser le curseur λ.
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            do {
                try store.save(model)
                self?.calibrationSaveError = nil
            } catch {
                self?.calibrationSaveError = "Calibration non enregistrée : \(error.localizedDescription)"
            }
        }
    }

    /// Réapprend la calibration si λ a changé dans les réglages.
    private func refitIfNeeded() {
        guard var model = calibration, model.regression.lambda != settings.ridgeLambda else { return }
        do {
            try model.refit(lambda: settings.ridgeLambda)
            calibration = model
            saveCalibration(immediately: false)
        } catch {
            // Garde l'ancien modèle ; le λ affiché reste celui des réglages.
        }
    }

    // MARK: - Caméra

    /// La caméra tourne tant que quelqu'un en a besoin.
    private var cameraNeeded: Bool {
        isDebugWindowOpen || calibrationSession != nil || isTrackingActive
    }

    private func updateCameraState() {
        camera.setPreviewEnabled(isDebugWindowOpen)
        if cameraNeeded {
            guard !isCameraRunning, !isCameraStarting else { return }
            isCameraStarting = true
            Task { await startCamera() }
        } else if isCameraRunning {
            camera.stop()
            isCameraRunning = false
            lastFrame = nil
            lastFeatures = nil
            gaze = nil
            fps = 0
        }
    }

    private func startCamera() async {
        defer { isCameraStarting = false }
        permissions.refresh()
        if permissions.camera == .notDetermined {
            await permissions.request(.camera)
        }
        guard permissions.camera == .granted else {
            cameraError = "Accès à la caméra non autorisé. Ouvrez l'écran d'accueil pour l'autoriser."
            return
        }
        do {
            cameraInfo = try await camera.start()
            cameraError = nil
            isCameraRunning = true
            // Le besoin a pu disparaître pendant le démarrage.
            if !cameraNeeded { updateCameraState() }
        } catch {
            cameraError = error.localizedDescription
        }
    }

    private func handle(_ output: CameraOutput) {
        guard isCameraRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastFrame = output.frame
        fps = output.fps
        if let preview = output.preview, isDebugWindowOpen {
            previewImage = preview.cgImage
        }
        camera.setPupilDarkFraction(settings.pupilDarkFraction)

        let face = output.frame.face
        let features = face.flatMap { GazeFeatures.make(from: $0, locator: settings.pupilLocator) }
        lastFeatures = features

        if let session = calibrationSession {
            let openness = [face?.leftEye?.openness, face?.rightEye?.openness].compactMap { $0 }.min() ?? 0
            session.ingest(features: features, openness: openness)
            return
        }

        refitIfNeeded()
        guard isTrackingActive, let model = calibration else { return }
        if let features {
            engine.setParameters(settings.gazeParameters)
            gaze = engine.process(raw: model.predict(features), timestamp: now, bounds: model.screenFrame)
            lastGazeUpdate = now
        } else if now - lastGazeUpdate > Self.gazeTimeout {
            gaze = nil
            engine.reset()
        }
        overlay.update(gaze: settings.showGazePoint ? gaze?.point : nil,
                       isFixating: gaze?.fixation != nil)
    }
}
