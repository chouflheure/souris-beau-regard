import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Paramètres d'une recherche de cible.
struct TargetQuery: Sendable, Equatable {
    /// Point de regard, Quartz.
    var point: CGPoint
    /// Rayon d'accroche, points écran.
    var radius: CGFloat
    /// Grille d'échantillonnage n × n.
    var gridSize: Int = 5
    /// Aire maximale d'une cible (points²) : au-delà, c'est un conteneur (page web, fenêtre…).
    var maxArea: CGFloat
    /// Délai maximal d'un appel d'accessibilité (s).
    var timeout: Float = 0.1
    /// Numéros de nos fenêtres transparentes (surlignage) à traverser.
    var ignoredWindowNumbers: Set<Int> = []
    /// App au premier plan : propriétaire des menus de la barre des menus.
    var frontmostPID: Int32?
}

struct TargetQueryResult: Sendable {
    var query: TargetQuery
    var candidates: [TargetCandidate]
    /// Durée de la recherche (s).
    var duration: Double
}

/// Trouve les éléments cliquables autour du regard avec l'API d'accessibilité.
///
/// `AXUIElementCopyElementAtPosition` sur une grille 5 × 5 de points, plutôt que de parcourir
/// tout l'arbre (énorme sur les pages web). Chaque élément touché est remonté jusqu'au premier
/// ancêtre cliquable. Résultats gardés 300 ms par case de la grille.
///
/// `@unchecked Sendable` : tout l'état (`cache`, `enabledPIDs`, éléments AX) n'est lu et modifié
/// que sur `queue` ; le drapeau `busy` est protégé par un verrou. Les éléments AX ne sortent jamais
/// de cette classe : on ne publie que des `TargetCandidate`, valeurs pures.
final class AXTargetFinder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.sourisbeauregard.accessibility", qos: .userInitiated)
    private let busy = OSAllocatedUnfairLock(initialState: false)

    // Sur `queue` uniquement.
    private let ownPID = getpid()
    private var cache: [String: (time: Double, candidate: TargetCandidate?)] = [:]
    private var enabledPIDs: Set<pid_t> = []
    private var windows: [(pid: pid_t, number: Int, layer: Int, bounds: CGRect)] = []
    private var windowsTime: Double = -1

    static let cacheLifetime = 0.3
    static let cacheCellSize: CGFloat = 20

    /// Rôles toujours considérés comme cliquables.
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXCell", "AXDisclosureTriangle", "AXTab", "AXSlider", "AXIncrementor", "AXColorWell",
        "AXDockItem",
    ]
    /// Rôles où l'on arrête de remonter.
    static let stopRoles: Set<String> = ["AXWindow", "AXApplication", "AXSheet", "AXDrawer", "AXSystemWide"]
    static let maxAncestors = 8

    /// Lance une recherche si aucune n'est en cours ; renvoie `false` sinon (la demande est ignorée).
    @discardableResult
    func query(_ query: TargetQuery, completion: @escaping @Sendable (TargetQueryResult) -> Void) -> Bool {
        let started = busy.withLock { isBusy -> Bool in
            if isBusy { return false }
            isBusy = true
            return true
        }
        guard started else { return false }
        queue.async {
            let result = self.run(query)
            self.busy.withLock { $0 = false }
            completion(result)
        }
        return true
    }

    // MARK: - Sur `queue`

    private func run(_ query: TargetQuery) -> TargetQueryResult {
        let start = ProcessInfo.processInfo.systemUptime
        guard query.point.x.isFinite, query.point.y.isFinite, query.radius.isFinite else {
            return TargetQueryResult(query: query, candidates: [], duration: 0)
        }
        var found: [String: TargetCandidate] = [:]
        for p in TargetGeometry.samplePoints(around: query.point, radius: query.radius, gridSize: query.gridSize) {
            let now = ProcessInfo.processInfo.systemUptime
            let key = TargetGeometry.cacheCell(for: p, cellSize: Self.cacheCellSize)
            let candidate: TargetCandidate?
            if let entry = cache[key], now - entry.time < Self.cacheLifetime {
                candidate = entry.candidate
            } else {
                candidate = hitTest(p, query: query)
                cache[key] = (now, candidate)
            }
            if let candidate { found[candidate.id] = candidate }
        }
        pruneCache()
        return TargetQueryResult(query: query, candidates: Array(found.values),
                                 duration: ProcessInfo.processInfo.systemUptime - start)
    }

    private func pruneCache() {
        guard cache.count > 2000 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        cache = cache.filter { now - $0.value.time < Self.cacheLifetime }
    }

    /// Élément sous le point, demandé **à l'app propriétaire de la fenêtre** sous ce point.
    ///
    /// On n'utilise pas l'élément « système » : quand le point tombe sur une fenêtre de notre app
    /// (icône de la barre des menus, débogage…), macOS ferait répondre notre app sur ce fil secondaire,
    /// qui toucherait alors l'interface hors du fil principal (plantage `NSMenu … non-main thread`).
    private func hitTest(_ p: CGPoint, query: TargetQuery) -> TargetCandidate? {
        guard p.x.isFinite, p.y.isFinite,
              let owner = windowOwner(at: p, ignoring: query.ignoredWindowNumbers, frontmostPID: query.frontmostPID),
              owner != ownPID else { return nil }
        let app = AXUIElementCreateApplication(owner)
        AXUIElementSetMessagingTimeout(app, query.timeout)
        enableAccessibilityIfNeeded(pid: owner, app: app)
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &element)
        guard error == .success, let element else { return nil }
        let elementPID = pid(of: element)
        guard elementPID != ownPID else { return nil }
        return clickableAncestor(of: element, pid: elementPID > 0 ? elementPID : owner, maxArea: query.maxArea)
    }

    private func clickableAncestor(of start: AXUIElement, pid: pid_t, maxArea: CGFloat) -> TargetCandidate? {
        var current: AXUIElement? = start
        for _ in 0..<Self.maxAncestors {
            guard let element = current else { return nil }
            let role = string(element, "AXRole") ?? ""
            if Self.stopRoles.contains(role) { return nil }
            if Self.clickableRoles.contains(role) || hasPressAction(element),
               let frame = frame(of: element), frame.width >= 2, frame.height >= 2,
               frame.width * frame.height <= maxArea {
                let title = string(element, "AXTitle") ?? string(element, "AXDescription")
                return TargetCandidate(id: TargetCandidate.makeID(pid: pid, role: role, frame: frame),
                                       frame: frame, role: role, title: title, pid: pid)
            }
            current = parent(of: element)
        }
        return nil
    }

    /// Chrome et les apps Electron n'exposent leurs éléments qu'à la demande.
    private func enableAccessibilityIfNeeded(pid: pid_t, app: AXUIElement) {
        guard !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual != .success {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// App propriétaire de la première fenêtre (de l'avant vers l'arrière) sous le point, en traversant
    /// nos fenêtres transparentes. Si c'est une autre fenêtre de notre app, renvoie notre PID (pas de cible).
    private func windowOwner(at p: CGPoint, ignoring ignored: Set<Int>, frontmostPID: pid_t?) -> pid_t? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowsTime > Self.cacheLifetime {
            windowsTime = now
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            windows = info.compactMap { w in
                guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                      let number = w[kCGWindowNumber as String] as? Int,
                      let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                else { return nil }
                let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
                guard alpha > 0.01 else { return nil }
                let layer = w[kCGWindowLayer as String] as? Int ?? 0
                return (pid, number, layer, bounds)
            }
        }
        guard let window = windows.first(where: { !ignored.contains($0.number) && $0.bounds.contains(p) }) else {
            return nil
        }
        // La barre des menus (niveau 24) appartient au serveur de fenêtres ; ses menus sont ceux de l'app active.
        if window.layer == Int(CGWindowLevelForKey(.mainMenuWindow)), let frontmostPID {
            return frontmostPID
        }
        return window.pid
    }

    // MARK: - Lecture d'attributs

    private func pid(of element: AXUIElement?) -> pid_t {
        guard let element else { return 0 }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(element, "AXParent"),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func hasPressAction(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains("AXPress")
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, "AXPosition"),
              let sizeValue = attribute(element, "AXSize"),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
