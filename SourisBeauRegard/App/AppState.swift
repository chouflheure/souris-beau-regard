import AppKit
import Observation
import SwiftUI

/// État central de l'app, sur le fil principal.
/// Reçoit les résultats de la caméra (republiés depuis sa file) et pilote les fenêtres.
@MainActor
@Observable
final class AppState {
    /// Instance unique, créée au premier accès sur le fil principal.
    static let shared = AppState()

    let permissions = PermissionsManager()
    let settings = AppSettings()
    let camera = CameraService()
    private let windows = WindowPresenter()

    // Derniers résultats de la caméra.
    private(set) var lastFrame: FaceFrame?
    private(set) var previewImage: CGImage?
    private(set) var fps: Double = 0
    private(set) var cameraInfo: CameraInfo?
    private(set) var cameraError: String?
    private(set) var isCameraRunning = false

    private(set) var isDebugWindowOpen = false
    @ObservationIgnored private var isCameraStarting = false

    /// Vrai pendant les tests unitaires (l'app hôte ne doit alors rien ouvrir).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        camera.setHandler { [weak self] output in
            Task { @MainActor in self?.handle(output) }
        }
    }

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching() {
        guard !Self.isRunningTests else { return }
        permissions.refresh()
        if !permissions.allRequiredGranted || !settings.hasCompletedOnboarding {
            showOnboarding()
        }
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
                     size: CGSize(width: 980, height: 560),
                     content: DebugView().environment(self)) { [weak self] in
            self?.isDebugWindowOpen = false
            self?.previewImage = nil
            self?.updateCameraState()
        }
    }

    // MARK: - Caméra

    /// La caméra tourne tant que quelqu'un en a besoin : pour l'instant la fenêtre de débogage ;
    /// à l'étape 2, le suivi du regard.
    private var cameraNeeded: Bool { isDebugWindowOpen }

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
            // La fenêtre a pu être fermée pendant le démarrage.
            if !cameraNeeded { updateCameraState() }
        } catch {
            cameraError = error.localizedDescription
        }
    }

    private func handle(_ output: CameraOutput) {
        guard isCameraRunning else { return }
        lastFrame = output.frame
        fps = output.fps
        if let preview = output.preview, isDebugWindowOpen {
            previewImage = preview.cgImage
        }
    }
}
