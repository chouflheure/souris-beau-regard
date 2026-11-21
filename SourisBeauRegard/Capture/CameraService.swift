import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import os

/// Informations sur la caméra ouverte, pour l'affichage.
struct CameraInfo: Sendable, Equatable {
    var id: String
    var name: String
    var width: Int
    var height: Int
    var frameRate: Double
}

/// Image d'aperçu réduite pour la fenêtre de débogage.
/// `CGImage` est immuable une fois créée : la partager entre files est sûr.
struct PreviewImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Une caméra disponible, pour le choix dans les réglages.
struct CameraDescriptor: Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
}

/// Recadrage d'un œil en pleine résolution, pour le débogage.
struct EyePreview: Sendable {
    let image: PreviewImage
    /// Zone recadrée, normalisée Vision (origine bas-gauche).
    let region: CGRect
}

/// Ce que la caméra publie à chaque image.
struct CameraOutput: Sendable {
    var frame: FaceFrame
    var preview: PreviewImage?
    /// Yeux gauche et droit (de l'image) agrandis, si l'aperçu est actif.
    var eyePreviews: [EyePreview] = []
    /// Effets vidéo de macOS actifs (vérifiés toutes les 30 images ; `nil` : pas vérifié à cette image).
    var videoEffects: [String]? = nil
    var fps: Double
}

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: "Aucune caméra trouvée."
        case .cannotAddInput: "Impossible d'ouvrir la caméra (déjà utilisée par une autre app ?)."
        case .cannotAddOutput: "Impossible de lire les images de la caméra."
        case .underlying(let message): message
        }
    }
}

/// Capture vidéo et analyse Vision, sur une file dédiée.
///
/// `@unchecked Sendable` est justifié ainsi :
/// - `session`, `analyzer`, `ciContext` et les variables d'état (`configuredInfo`, `frameTimes`…)
///   ne sont lus et modifiés **que** sur `queue` (configuration, démarrage, arrêt et callback
///   `captureOutput` y sont tous exécutés) ;
/// - l'état partagé avec le fil principal (`shared`) est protégé par un verrou.
/// Les résultats sont des valeurs `Sendable`, remises au gestionnaire qui les republie sur `@MainActor`.
final class CameraService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {

    private struct Shared: Sendable {
        var previewEnabled = false
        var irisFraction = 0.3
        var preferredCameraID: String?
        var handler: (@Sendable (CameraOutput) -> Void)?
    }

    /// Largeur de l'aperçu de débogage, en pixels.
    static let previewWidth: CGFloat = 640

    private let queue = DispatchQueue(label: "fr.sourisbeauregard.camera", qos: .userInteractive)
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    // Accédés uniquement sur `queue`.
    private let session = AVCaptureSession()
    private let analyzer = FaceAnalyzer()
    private let visionPupilLocator = VisionPupilLocator()
    private var imagePupilLocator = ImagePupilLocator()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var configuredInfo: CameraInfo?
    private var device: AVCaptureDevice?
    private var frameCounter = 0
    private var lastFrameTime: Double?
    private var smoothedFPS: Double = 0

    // MARK: - API (appelable depuis n'importe quel fil)

    func setHandler(_ handler: @escaping @Sendable (CameraOutput) -> Void) {
        shared.withLock { $0.handler = handler }
    }

    func setPreviewEnabled(_ enabled: Bool) {
        shared.withLock { $0.previewEnabled = enabled }
    }

    /// Caméra à utiliser (`nil` : automatique). Prise en compte au prochain `rebuild()`.
    func setPreferredCamera(_ id: String?) {
        shared.withLock { $0.preferredCameraID = id }
    }

    /// Caméras disponibles : intégrée, externes, et iPhone (Caméra de continuité).
    static func availableCameras() -> [CameraDescriptor] {
        discoverySession().devices.map { CameraDescriptor(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
    }

    func setIrisFraction(_ fraction: Double) {
        shared.withLock { $0.irisFraction = fraction }
    }

    /// Configure (la première fois) et démarre la capture. L'autorisation caméra doit être accordée.
    func start() async throws -> CameraInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CameraInfo, Error>) in
            queue.async {
                do {
                    let info = try self.configureIfNeeded()
                    if !self.session.isRunning {
                        self.lastFrameTime = nil
                        self.smoothedFPS = 0
                        self.session.startRunning()
                    }
                    continuation.resume(returning: info)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private var runtimeErrorObserver: (any NSObjectProtocol)?

    override init() {
        super.init()
        // Erreur d'exécution de la capture (caméra débranchée, prise par une autre app…) : relance.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] _ in
            self?.restart()
        }
    }

    deinit {
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
    }

    /// Démonte et reconfigure entièrement la session (quand une simple relance ne suffit pas).
    func rebuild() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.configuredInfo = nil
            self.lastFrameTime = nil
            self.smoothedFPS = 0
            if (try? self.configureIfNeeded()) != nil {
                self.session.startRunning()
            }
        }
    }

    /// Arrête puis relance la capture (caméra figée, réveil de veille, erreur d'exécution).
    func restart() {
        queue.async {
            guard self.configuredInfo != nil else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.lastFrameTime = nil
            self.smoothedFPS = 0
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - Configuration (sur `queue`)

    private func configureIfNeeded() throws -> CameraInfo {
        if let configuredInfo { return configuredInfo }
        let preferred = shared.withLock { $0.preferredCameraID }
        guard let device = Self.pickDevice(preferredID: preferred) else { throw CameraError.noCamera }
        self.device = device
        // Cadre centré recadre et zoome en suivant le visage : les mesures de position de la tête
        // deviendraient fausses. L'app le désactive pour elle-même.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.underlying(error.localizedDescription)
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        // Plus de pixels sur les yeux = pupille mieux localisée.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        // 30 images/s si le format actif le permet.
        var frameRate = 30.0
        do {
            try device.lockForConfiguration()
            let supports30 = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
            if supports30 {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            } else {
                frameRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            }
            device.unlockForConfiguration()
        } catch {
            // Pas bloquant : on garde le débit par défaut.
        }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let info = CameraInfo(id: device.uniqueID,
                              name: device.localizedName,
                              width: Int(dims.width),
                              height: Int(dims.height),
                              frameRate: frameRate)
        configuredInfo = info
        return info
    }

    /// Caméra intégrée en priorité, sinon la première caméra externe.
    /// La caméra choisie si elle est branchée, sinon l'intégrée, sinon la première trouvée.
    private static func pickDevice(preferredID: String?) -> AVCaptureDevice? {
        let devices = discoverySession().devices
        if let preferredID, let chosen = devices.first(where: { $0.uniqueID == preferredID }) { return chosen }
        return devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first
    }

    /// Effets vidéo de macOS qui modifient l'image (Centre de contrôle ▸ Effets vidéo).
    private func activeVideoEffects() -> [String] {
        guard let device else { return [] }
        var effects: [String] = []
        if device.isPortraitEffectActive { effects.append("Portrait") }
        if device.isStudioLightActive { effects.append("Studio Light") }
        if device.isCenterStageActive { effects.append("Cadre centré") }
        if AVCaptureDevice.reactionEffectsEnabled { effects.append("Réactions") }
        return effects
    }

    // MARK: - Images (sur `queue`)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let state = shared.withLock { $0 }
        guard let handler = state.handler else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        updateFPS(timestamp: timestamp)

        let start = DispatchTime.now().uptimeNanoseconds
        var face = analyzer.analyze(pixelBuffer: pixelBuffer)
        // Les deux PupilLocator tournent à chaque image, pour pouvoir les comparer.
        imagePupilLocator.irisFraction = state.irisFraction
        if var f = face {
            for keyPath in [\FaceMeasurement.leftEye, \FaceMeasurement.rightEye] {
                guard var eye = f[keyPath: keyPath] else { continue }
                eye.visionPupil = visionPupilLocator.locate(eye: eye, pixelBuffer: pixelBuffer)
                eye.imagePupil = imagePupilLocator.locate(eye: eye, pixelBuffer: pixelBuffer)
                f[keyPath: keyPath] = eye
            }
            face = f
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        let frame = FaceFrame(
            imageSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                              height: CVPixelBufferGetHeight(pixelBuffer)),
            face: face,
            processingTime: elapsed,
            timestamp: timestamp)

        // L'aperçu n'est fabriqué que si la fenêtre de débogage est ouverte. Jamais écrit sur disque.
        let preview = state.previewEnabled ? makePreview(pixelBuffer) : nil
        var eyes: [EyePreview] = []
        if state.previewEnabled, let face {
            eyes = [face.leftEye, face.rightEye].compactMap { eye in
                eye.flatMap { makeEyePreview(pixelBuffer, box: $0.box) }
            }
        }
        frameCounter += 1
        let effects = frameCounter % 30 == 1 ? activeVideoEffects() : nil
        handler(CameraOutput(frame: frame, preview: preview, eyePreviews: eyes, videoEffects: effects, fps: smoothedFPS))
    }

    private func updateFPS(timestamp: Double) {
        defer { lastFrameTime = timestamp }
        guard let last = lastFrameTime, timestamp > last else { return }
        let instant = 1 / (timestamp - last)
        smoothedFPS = smoothedFPS == 0 ? instant : smoothedFPS * 0.9 + instant * 0.1
    }

    /// Zone autour de l'œil (2 × sa largeur, 4 × sa hauteur), en pleine résolution.
    private func makeEyePreview(_ pixelBuffer: CVPixelBuffer, box: CGRect) -> EyePreview? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let w = image.extent.width, h = image.extent.height
        // CIImage a son origine en bas à gauche, comme Vision : pas de retournement.
        let eye = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
        let side = max(eye.width * 2, eye.height * 4)
        let rect = CGRect(x: eye.midX - side / 2, y: eye.midY - side / 4, width: side, height: side / 2)
            .integral.intersection(image.extent)
        guard !rect.isNull, rect.width >= 4, rect.height >= 4,
              let cg = ciContext.createCGImage(image, from: rect) else { return nil }
        let region = CGRect(x: rect.minX / w, y: rect.minY / h, width: rect.width / w, height: rect.height / h)
        return EyePreview(image: PreviewImage(cgImage: cg), region: region)
    }

    private func makePreview(_ pixelBuffer: CVPixelBuffer) -> PreviewImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = Self.previewWidth / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return PreviewImage(cgImage: cg)
    }
}
