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
    /// Pourquoi le regard n'est pas suivi en ce moment (affiché dans le débogage), ou `nil`.
    private(set) var gazeLossReason: String?
    /// Bruit du regard brut sur la dernière seconde (points).
    private(set) var gazeSpread: Double?
    /// Nombre de relances automatiques de la caméra (image figée).
    private(set) var cameraRestarts = 0
    /// Recentrage en cours.
    private(set) var isRecentering = false
    /// Résultat du dernier recentrage, pour l'affichage.
    private(set) var recenterMessage: String?
    /// Le raccourci de recentrage a pu être enregistré.
    private(set) var recenterShortcutAvailable = false
    private(set) var calibrationSaveError: String?

    private(set) var isDebugWindowOpen = false
    @ObservationIgnored private var isCameraStarting = false
    @ObservationIgnored private var engine = GazeEngine()
    @ObservationIgnored private var lastGazeUpdate: Double = 0
    @ObservationIgnored private var lastGazePoint: CGPoint?
    @ObservationIgnored private var lastFrameArrival: Double = 0
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var recenterStart: Double = 0
    @ObservationIgnored private var recenterSamples: [CGPoint] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Vrai pendant les tests unitaires (l'app hôte ne doit alors rien ouvrir).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Délai sans mesure valide après lequel le point passe en « regard perdu » (s).
    private static let gazeTimeout = 0.5
    /// Délai sans image après lequel la caméra est relancée (s).
    private static let cameraStallTimeout = 2.0

    init() {
        camera.setHandler { [weak self] output in
            Task { @MainActor in self?.handle(output) }
        }
        settings.onGazeDisplayChange = { [weak self] in self?.gazeDisplayChanged() }
    }

    /// Relance la caméra si elle ne livre plus d'images (veille, autre app, erreur) ;
    /// remet le panneau de surlignage à sa place si les écrans changent.
    private func startWatchdogs() {
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.checkCameraStall()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func checkCameraStall() {
        guard isCameraRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrameArrival > Self.cameraStallTimeout {
            cameraRestarts += 1
            lastFrameArrival = now
            camera.restart()
        }
    }

    private func screensChanged() {
        overlay.hide()
        updateOverlay()
    }

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching() {
        guard !Self.isRunningTests else { return }
        permissions.refresh()
        calibration = store.load()
        startWatchdogs()
        recenterShortcutAvailable = GlobalHotKeys.shared.register(GlobalHotKeys.recenter) { [weak self] in
            self?.recenter()
        }
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
            if !overlay.isVisible || overlay.displayedScreenFrame != ScreenGeometry.quartzFrame(of: screen) {
                overlay.show(on: screen)
            }
        } else {
            overlay.hide()
        }
    }

    // MARK: - Recentrage

    /// Durée d'affichage du point de recentrage et fenêtre de mesures gardées (s).
    private static let recenterDuration = 1.5
    private static let recenterWindow: ClosedRange<Double> = 0.5...1.5

    /// Affiche un point au centre de l'écran calibré ; l'écart entre ce point et le regard mesuré
    /// devient un décalage ajouté aux prédictions, jusqu'à la prochaine calibration.
    func recenter() {
        guard isTrackingActive, let calibration, !isRecentering else {
            recenterMessage = calibration == nil ? "Calibrez d'abord." : recenterMessage
            return
        }
        if !overlay.isVisible, let screen = ScreenGeometry.screen(matchingQuartzFrame: calibration.screenFrame) {
            overlay.show(on: screen)
        }
        isRecentering = true
        recenterSamples = []
        recenterStart = ProcessInfo.processInfo.systemUptime
        overlay.showRecenterTarget(CGPoint(x: calibration.screenFrame.midX, y: calibration.screenFrame.midY))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.recenterDuration))
            self?.finishRecenter()
        }
    }

    private func finishRecenter() {
        isRecentering = false
        overlay.showRecenterTarget(nil)
        updateOverlay()
        guard var model = calibration, recenterSamples.count >= 5 else {
            recenterMessage = "Recentrage impossible : regard non mesuré (visage bien visible ?)."
            return
        }
        let measured = CGPoint(x: Stats.median(recenterSamples.map { Double($0.x) }),
                               y: Stats.median(recenterSamples.map { Double($0.y) }))
        model.offset = CGPoint(x: model.screenFrame.midX - measured.x, y: model.screenFrame.midY - measured.y)
        calibration = model
        engine.reset()
        recenterMessage = String(format: "Décalage corrigé : %.0f, %.0f pt", model.offset.x, model.offset.y)
        saveCalibration(immediately: true)
    }

    func clearRecenterOffset() {
        guard var model = calibration else { return }
        model.offset = .zero
        calibration = model
        engine.reset()
        recenterMessage = nil
        saveCalibration(immediately: true)
    }

    // MARK: - Calibration

    func startCalibration() {
        guard calibrationSession == nil, let screen = ScreenGeometry.screenUnderMouse() else { return }
        let session = CalibrationSession(screenFrame: ScreenGeometry.quartzFrame(of: screen),
                                         plan: settings.calibrationPlan,
                                         pupilLocator: settings.pupilLocator,
                                         kind: settings.modelChoice,
                                         lambda: settings.lambdaAuto ? nil : settings.ridgeLambda,
                                         trainOnValidation: settings.trainOnValidation)
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

    /// Modèle et λ voulus d'après les réglages (le choix automatique est celui fait à la calibration).
    private func desiredFit(for model: CalibrationModel) -> (kind: GazeModelKind, lambda: Double) {
        let kind = settings.modelChoice ?? model.autoKind ?? model.kind
        let lambda = settings.lambdaAuto ? (model.autoLambda ?? model.lambda) : settings.ridgeLambda
        return (kind, lambda)
    }

    /// Réapprend la calibration si le modèle ou λ a changé dans les réglages.
    private func refitIfNeeded() {
        guard var model = calibration else { return }
        let wanted = desiredFit(for: model)
        guard wanted.kind != model.kind || wanted.lambda != model.lambda else { return }
        do {
            try model.refit(kind: wanted.kind, lambda: wanted.lambda)
            calibration = model
            saveCalibration(immediately: false)
        } catch {
            // Garde l'ancien modèle.
        }
    }

    /// Ouvre le dossier des données de calibration dans le Finder.
    func revealCalibrationFile() {
        if FileManager.default.fileExists(atPath: store.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.url])
        } else {
            NSWorkspace.shared.open(store.url.deletingLastPathComponent())
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
            lastFrameArrival = ProcessInfo.processInfo.systemUptime
            // Le besoin a pu disparaître pendant le démarrage.
            if !cameraNeeded { updateCameraState() }
        } catch {
            cameraError = error.localizedDescription
        }
    }

    private func handle(_ output: CameraOutput) {
        guard isCameraRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastFrameArrival = now
        lastFrame = output.frame
        fps = output.fps
        if let preview = output.preview, isDebugWindowOpen {
            previewImage = preview.cgImage
        }
        camera.setPupilDarkFraction(settings.pupilDarkFraction)

        let face = output.frame.face
        let features = face.flatMap { GazeFeatures.make(from: $0, imageSize: output.frame.imageSize, locator: settings.pupilLocator) }
        lastFeatures = features

        if let session = calibrationSession {
            let openness = [face?.leftEye?.openness, face?.rightEye?.openness].compactMap { $0 }.min() ?? 0
            session.ingest(features: features, openness: openness)
            return
        }

        refitIfNeeded()
        guard isTrackingActive, let model = calibration else { return }
        // Le panneau a pu être retiré par le système (changement d'écran, de bureau…).
        if settings.showGazePoint, !overlay.isVisible { updateOverlay() }

        // Clignement : les pupilles sont fausses sur ces images, on garde la dernière position.
        let openness = [face?.leftEye?.openness, face?.rightEye?.openness].compactMap { $0 }.min() ?? 0
        let isBlink = features != nil && openness < settings.minEyeOpenness
        let valid = features.flatMap { f -> GazeFeatures? in
            (isBlink || !f.vector.allSatisfy(\.isFinite)) ? nil : f
        }

        if isRecentering, let valid {
            let elapsed = now - recenterStart
            let p = model.predictUncorrected(valid)
            if Self.recenterWindow.contains(elapsed), GazeEngine.isFinite(p) { recenterSamples.append(p) }
        }

        var estimate: GazeEstimate?
        if let valid {
            engine.setParameters(settings.gazeParameters)
            estimate = engine.process(raw: model.predict(valid), timestamp: now, bounds: model.screenFrame)
        }

        if let estimate {
            gaze = estimate
            gazeSpread = engine.rawSpread
            gazeLossReason = estimate.isOffScreen ? "Prédiction hors de l'écran (tête déplacée depuis la calibration ?)" : nil
            lastGazeUpdate = now
            lastGazePoint = estimate.point
        } else if now - lastGazeUpdate > Self.gazeTimeout {
            gazeLossReason = face == nil ? "Visage non détecté"
                : isBlink ? "Yeux fermés ou mal vus (ouverture sous le seuil)"
                : features == nil ? "Pupille non trouvée"
                : "Mesure invalide"
            if gaze != nil {
                gaze = nil
                engine.reset()
            }
        }

        guard settings.showGazePoint else {
            overlay.update(gaze: nil, status: .tracking)
            return
        }
        if let gaze {
            let status: GazeDisplayStatus = gaze.isOffScreen ? .offScreen
                : gaze.fixation != nil ? .fixating : .tracking
            overlay.update(gaze: gaze.point, status: status)
        } else {
            // Regard perdu : cercle gris à la dernière position, pour ne pas « disparaître ».
            overlay.update(gaze: lastGazePoint, status: .lost)
        }
    }
}
