import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid
import Observation

enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined

    var label: String {
        switch self {
        case .granted: "Autorisé"
        case .denied: "Non autorisé"
        case .notDetermined: "Pas encore demandé"
        }
    }
}

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case camera
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Caméra"
        case .accessibility: "Accessibilité"
        case .inputMonitoring: "Surveillance de l'entrée"
        }
    }

    var explanation: String {
        switch self {
        case .camera:
            "Pour suivre le regard. Les images restent sur ce Mac, rien n'est enregistré."
        case .accessibility:
            "Pour lire les boutons à l'écran, envoyer les clics et intercepter la touche de clic."
        case .inputMonitoring:
            "Peut être demandée par macOS pour intercepter la touche de clic. Facultative si l'Accessibilité suffit."
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    var isRequired: Bool { self != .inputMonitoring }

    /// Panneau correspondant des Réglages Système.
    var settingsURL: URL {
        let anchor = switch self {
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// État des trois autorisations, rafraîchi régulièrement pendant que l'écran d'accueil est ouvert
/// (macOS ne notifie pas les changements d'Accessibilité).
@MainActor
@Observable
final class PermissionsManager {
    private(set) var camera: PermissionStatus = .notDetermined
    private(set) var accessibility: PermissionStatus = .notDetermined
    private(set) var inputMonitoring: PermissionStatus = .notDetermined

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var allRequiredGranted: Bool {
        Permission.allCases.filter(\.isRequired).allSatisfy { status(of: $0) == .granted }
    }

    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .camera: camera
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }

    func refresh() {
        camera = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }

        // L'API ne distingue pas « refusé » de « jamais demandé ».
        accessibility = AXIsProcessTrusted() ? .granted : .denied

        let hid = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if hid == kIOHIDAccessTypeGranted {
            inputMonitoring = .granted
        } else if hid == kIOHIDAccessTypeDenied {
            inputMonitoring = .denied
        } else {
            inputMonitoring = .notDetermined
        }
    }

    func request(_ permission: Permission) async {
        switch permission {
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            } else {
                openSettings(for: .camera)
            }
        case .accessibility:
            // Clé de `kAXTrustedCheckOptionPrompt`, écrite en clair pour éviter une variable
            // globale C non `Sendable` en Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
                openSettings(for: .inputMonitoring)
            }
        }
        refresh()
    }

    func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
