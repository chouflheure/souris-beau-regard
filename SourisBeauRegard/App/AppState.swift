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
    private let trainingWindow = TrainingWindowController()
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
    private(set) var trainingSession: TrainingSession?
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

    // Apprentissage par les clics.
    private(set) var clicksAccepted = 0
    private(set) var clicksRejected = 0
    private(set) var lastClickError: Double?

    // Ciblage.
    private(set) var currentTarget: TargetCandidate?
    private(set) var targetCandidateCount = 0
    private(set) var targetQueryDuration: Double?

    private(set) var isDebugWindowOpen = false
    @ObservationIgnored private var isCameraStarting = false
    @ObservationIgnored private var engine = GazeEngine()
    @ObservationIgnored private var lastGazeUpdate: Double = 0
    @ObservationIgnored private var lastGazePoint: CGPoint?
    @ObservationIgnored private var lastFrameArrival: Double = 0
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var recenterStart: Double = 0
    @ObservationIgnored private var recenterSamples: [GazeFeatures] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let targetFinder = AXTargetFinder()
    @ObservationIgnored private var targetSelector = TargetSelector()
    @ObservationIgnored private(set) var targetHistory = TargetHistory()
    @ObservationIgnored private var lastTargetQuery: Double = 0
    @ObservationIgnored private var lastCameraStart: Double = 0
    @ObservationIgnored private var recentStalls: [Double] = []
    /// Mesures valides de la dernière seconde, pour apprendre des clics.
    @ObservationIgnored private var recentFeatures: [(time: Double, features: GazeFeatures)] = []
    @ObservationIgnored private var clickMonitor: Any?
    /// Empêche App Nap de ralentir l'app pendant le suivi (app de barre des menus sans fenêtre visible).
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

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
                self?.permissions.refresh()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func checkCameraStall() {
        let now = ProcessInfo.processInfo.systemUptime
        // Démarrage raté (caméra occupée au lancement…) : on réessaie toutes les 3 s.
        if cameraNeeded, !isCameraRunning, !isCameraStarting, now - lastCameraStart > 3 {
            updateCameraState()
            return
        }
        guard isCameraRunning, now - lastFrameArrival > Self.cameraStallTimeout else { return }
        cameraRestarts += 1
        lastFrameArrival = now
        recentStalls = recentStalls.filter { now - $0 < 15 } + [now]
        // Deuxième blocage rapproché : une simple relance ne suffit pas, on reconstruit la session.
        if recentStalls.count >= 2 {
            recentStalls = []
            camera.rebuild()
        } else {
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
        startClickLearning()
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
        settings.trackingEnabled && calibration != nil && calibrationSession == nil && trainingSession == nil
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
        if isTrackingActive, settings.showGazePoint || settings.targetingEnabled, let calibration,
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
        // Le recentrage remplace l'historique des écarts (la tête a sans doute bougé),
        // sans ajouter ces mesures à l'apprentissage.
        model.learn(from: recenterSamples, target: CGPoint(x: model.screenFrame.midX, y: model.screenFrame.midY),
                    maxError: nil, resetHistory: true, addToTraining: false,
                    eventWindow: settings.learningEventWindow)
        calibration = model
        engine.reset()
        recenterMessage = String(format: "Décalage corrigé : %.0f, %.0f pt", model.offset.x, model.offset.y)
        saveCalibration(immediately: true)
    }

    func clearRecenterOffset() {
        guard var model = calibration else { return }
        model.offset = .zero
        model.recentEvents = []
        calibration = model
        engine.reset()
        recenterMessage = nil
        saveCalibration(immediately: true)
    }

    // MARK: - Apprentissage par les clics

    /// Écoute (sans les intercepter) les clics de la vraie souris : on regarde presque toujours ce
    /// qu'on clique, chaque clic est donc un point de calibration gratuit.
    private func startClickLearning() {
        guard clickMonitor == nil else { return }
        // Appelé sur le fil principal ; n'intercepte rien (écoute seule).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.learnFromClick(atAppKit: NSEvent.mouseLocation) }
        }
    }

    private func learnFromClick(atAppKit location: CGPoint) {
        guard settings.learnFromClicks, isTrackingActive, !isRecentering, var model = calibration else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let target = CoordinateSpaces.appKitToQuartz(location, primaryScreenHeight: ScreenGeometry.primaryScreenHeight)
        // Clic sur un autre écran que celui calibré : rien à apprendre.
        guard model.screenFrame.contains(target) else { return }
        let window = (now - settings.learningLookBackEnd)...(now - settings.learningLookBackStart)
        let features = recentFeatures.filter { window.contains($0.time) }.map { $0.features }
        guard features.count >= 3 else { return }
        let before = model.predict(features[features.count / 2])
        lastClickError = Double(hypot(before.x - target.x, before.y - target.y))
        let outcome = model.learn(from: features, target: target, maxError: settings.learningMaxError,
                                  eventWindow: settings.learningEventWindow)
        guard outcome == .accepted else {
            clicksRejected += 1
            return
        }
        clicksAccepted += 1
        if let count = model.implicitEventCount, count.isMultiple(of: Self.refitEveryClicks) {
            try? model.refitWithImplicitSamples()
        }
        calibration = model
        engine.reset()
        saveCalibration(immediately: false)
    }

    /// Nombre de clics retenus entre deux réapprentissages du modèle.
    private static let refitEveryClicks = 20

    // MARK: - Entraînement

    /// Exercice : cliquer à la souris des cibles en les regardant ; les mesures enrichissent le modèle.
    func startTraining() {
        guard trainingSession == nil, calibrationSession == nil, let calibration,
              let screen = ScreenGeometry.screen(matchingQuartzFrame: calibration.screenFrame) else { return }
        let session = TrainingSession(screenFrame: ScreenGeometry.quartzFrame(of: screen),
                                      count: settings.trainingTargetCount,
                                      lookBack: settings.learningLookBackStart...settings.learningLookBackEnd)
        session.featuresProvider = { [weak self] window in
            self?.recentFeatures.filter { window.contains($0.time) }.map { $0.features } ?? []
        }
        session.predictor = { [weak self] features in
            self?.calibration?.predict(features) ?? .zero
        }
        session.onFinish = { [weak self] groups, before in
            self?.finishTraining(groups, beforeError: before)
        }
        session.onClose = { [weak self] in self?.closeTraining() }
        trainingSession = session
        overlay.hide()
        updateCameraState()
        trainingWindow.present(session, on: screen)
    }

    private func finishTraining(_ groups: [[CalibrationSample]]?, beforeError: Double?) {
        guard let groups, let session = trainingSession else { return }   // annulé
        guard !groups.isEmpty, var model = calibration else {
            session.showFailure("Aucune cible mesurée : le visage était-il bien visible ?")
            return
        }
        model.addTraining(groups, eventWindow: settings.learningEventWindow)
        let snapshot = model
        let kind = settings.modelChoice
        let lambda: Double? = settings.lambdaAuto ? nil : settings.ridgeLambda
        Task { [weak self] in
            // Choix du modèle et de λ sur toutes les mesures : quelques centaines d'apprentissages,
            // faits hors du fil principal.
            let outcome = await Task.detached { () -> Result<CalibrationModel, any Error> in
                var updated = snapshot
                do {
                    try updated.relearn(kind: kind, lambda: lambda)
                    return .success(updated)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let updated):
                self.calibration = updated
                self.engine.reset()
                self.saveCalibration(immediately: true)
                session.showResult(after: updated.crossValidationError)
            case .failure(let error):
                session.showFailure(error.localizedDescription)
            }
        }
    }

    private func closeTraining() {
        trainingWindow.close()
        trainingSession = nil
        updateCameraState()
        updateOverlay()
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
        isDebugWindowOpen || calibrationSession != nil || trainingSession != nil || isTrackingActive
    }

    private func updateCameraState() {
        camera.setPreviewEnabled(isDebugWindowOpen)
        if cameraNeeded {
            guard !isCameraRunning, !isCameraStarting else { return }
            isCameraStarting = true
            Task { await startCamera() }
        } else if isCameraRunning {
            camera.stop()
            endActivity()
            isCameraRunning = false
            currentTarget = nil
            targetSelector.reset()
            lastFrame = nil
            lastFeatures = nil
            gaze = nil
            fps = 0
        }
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Suivi du regard en continu")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func startCamera() async {
        lastCameraStart = ProcessInfo.processInfo.systemUptime
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
            beginActivity()
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
        guard let model = calibration else { return }

        // Clignement : les pupilles sont fausses sur ces images, on garde la dernière position.
        let openness = [face?.leftEye?.openness, face?.rightEye?.openness].compactMap { $0 }.min() ?? 0
        let isBlink = features != nil && openness < settings.minEyeOpenness
        let valid = features.flatMap { f -> GazeFeatures? in
            (isBlink || !f.vector.allSatisfy(\.isFinite)) ? nil : f
        }

        // Mesures de la dernière seconde (apprentissage par les clics et exercice d'entraînement).
        if let valid {
            recentFeatures.append((now, valid))
            if let first = recentFeatures.first, now - first.time > 1.0 {
                recentFeatures.removeAll { now - $0.time > 1.0 }
            }
        }

        guard isTrackingActive else { return }
        // Le panneau a pu être retiré par le système (changement d'écran, de bureau…).
        if settings.showGazePoint, !overlay.isVisible { updateOverlay() }

        if isRecentering, let valid {
            let elapsed = now - recenterStart
            if Self.recenterWindow.contains(elapsed), GazeEngine.isFinite(model.predictUncorrected(valid)) {
                recenterSamples.append(valid)
            }
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

        if let gaze {
            let status: GazeDisplayStatus = gaze.isOffScreen ? .offScreen
                : gaze.fixation != nil ? .fixating : .tracking
            overlay.update(gaze: gaze.point, status: status)
        } else {
            // Regard perdu : cercle gris à la dernière position, pour ne pas « disparaître ».
            overlay.update(gaze: lastGazePoint, status: .lost)
        }
        updateTargeting(now: now)
    }

    // MARK: - Ciblage

    /// Lance une recherche de cible autour du regard (au plus `targetingRate` fois par seconde,
    /// jamais deux à la fois) ; le résultat arrive dans `handleTargets`.
    private func updateTargeting(now: Double) {
        guard settings.targetingEnabled, permissions.accessibility == .granted,
              let gaze, let calibration else {
            if currentTarget != nil { currentTarget = nil }
            targetSelector.reset()
            targetHistory.record(nil, at: now)
            overlay.update(target: nil, showGazeWithTarget: settings.showGazePoint)
            return
        }
        targetSelector.hysteresis = settings.targetHysteresis
        targetSelector.radius = CGFloat(settings.snapRadius)
        targetSelector.stickiness = CGFloat(settings.targetStickiness)
        guard now - lastTargetQuery >= 1 / settings.targetingRate else { return }
        let screen = calibration.screenFrame
        let query = TargetQuery(point: gaze.point, radius: CGFloat(settings.snapRadius),
                                maxArea: screen.width * screen.height * CGFloat(settings.maxTargetFraction))
        let started = targetFinder.query(query, completion: { [weak self] result in
            Task { @MainActor in self?.handleTargets(result) }
        })
        if started { lastTargetQuery = now }
    }

    private func handleTargets(_ result: TargetQueryResult) {
        guard isTrackingActive, settings.targetingEnabled, gaze != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let point = gaze?.point ?? result.query.point
        currentTarget = targetSelector.update(candidates: result.candidates, gaze: point, time: now)
        targetCandidateCount = result.candidates.count
        targetQueryDuration = result.duration
        targetHistory.record(currentTarget, at: now)
        overlay.update(target: currentTarget?.frame, showGazeWithTarget: settings.showGazePoint)
    }

    // MARK: - État affiché

    /// Symbole de la barre des menus : œil plein = suivi, barré = regard perdu.
    var menuBarSymbol: String {
        guard isTrackingActive else { return "eye" }
        return gaze == nil ? "eye.slash" : "eye.fill"
    }

    /// Ligne d'état du menu.
    var gazeStatusText: String {
        if calibration == nil { return "Pas encore calibré" }
        if !settings.trackingEnabled { return "Suivi en pause" }
        if calibrationSession != nil { return "Calibration en cours" }
        if let cameraError { return "Caméra : \(cameraError)" }
        if !isCameraRunning { return "Démarrage de la caméra…" }
        if gaze == nil { return "Regard perdu : \(gazeLossReason ?? "en attente")" }
        if let target = currentTarget { return "Cible : \(target.title ?? target.role)" }
        return "Regard suivi"
    }
}
