import CoreGraphics

/// Le seul endroit de l'app où l'on passe d'un repère à un autre.
///
/// Trois repères cohabitent :
/// - **Vision** : coordonnées normalisées (0…1), origine en **bas à gauche** de l'image.
///   Les repères du visage (`normalizedPoints`) sont en plus relatifs à la boîte du visage.
/// - **AppKit** (`NSScreen`, `NSWindow`) : points écran, origine en **bas à gauche** de l'écran principal.
/// - **Quartz** (`CGEvent`, accessibilité, `CGDisplayBounds`) : points écran, origine en **haut à gauche**
///   de l'écran principal, y vers le bas.
///
/// Les vues SwiftUI ont aussi l'origine en haut à gauche, y vers le bas.
/// Tout ici est de la logique pure, sans AppKit, et testé dans `CoordinateSpacesTests`.
enum CoordinateSpaces {

    // MARK: - Vision

    /// Repère du visage (relatif à la boîte) → repère normalisé de l'image Vision.
    static func landmarkToImage(_ point: CGPoint, faceBoundingBox box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + point.x * box.width,
                y: box.minY + point.y * box.height)
    }

    /// Normalisé Vision (origine bas-gauche) → pixels de l'image (origine haut-gauche).
    static func visionToImagePixels(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * imageSize.width,
                y: (1 - point.y) * imageSize.height)
    }

    /// Rectangle normalisé Vision → rectangle en pixels de l'image (origine haut-gauche).
    static func visionRectToImagePixels(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: rect.minX * imageSize.width,
               y: (1 - rect.maxY) * imageSize.height,
               width: rect.width * imageSize.width,
               height: rect.height * imageSize.height)
    }

    /// Normalisé Vision → point d'une vue (origine haut-gauche) où l'image occupe `imageRect`.
    /// `mirrored` retourne l'image horizontalement, comme un miroir.
    static func visionToView(_ point: CGPoint, imageRect: CGRect, mirrored: Bool) -> CGPoint {
        let nx = mirrored ? 1 - point.x : point.x
        let ny = 1 - point.y
        return CGPoint(x: imageRect.minX + nx * imageRect.width,
                       y: imageRect.minY + ny * imageRect.height)
    }

    /// Rectangle normalisé Vision → rectangle d'une vue (origine haut-gauche).
    static func visionRectToView(_ rect: CGRect, imageRect: CGRect, mirrored: Bool) -> CGRect {
        let a = visionToView(CGPoint(x: rect.minX, y: rect.minY), imageRect: imageRect, mirrored: mirrored)
        let b = visionToView(CGPoint(x: rect.maxX, y: rect.maxY), imageRect: imageRect, mirrored: mirrored)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Rectangle occupé par un contenu de taille `contentSize` affiché en « aspect fit » dans `bounds`.
    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: - AppKit ↔ Quartz

    /// `primaryScreenHeight` : hauteur de l'écran principal (celui qui porte la barre des menus),
    /// c'est-à-dire `NSScreen.screens[0].frame.height`.
    static func appKitToQuartz(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func quartzToAppKit(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func appKitRectToQuartz(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    static func quartzRectToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    // MARK: - Écran normalisé

    /// Point normalisé dans un écran (0…1, origine haut-gauche) → point Quartz.
    static func normalizedToQuartz(_ point: CGPoint, screenFrameQuartz frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width,
                y: frame.minY + point.y * frame.height)
    }

    /// Point Quartz → point normalisé dans un écran (0…1, origine haut-gauche).
    static func quartzToNormalized(_ point: CGPoint, screenFrameQuartz frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (point.x - frame.minX) / frame.width,
                       y: (point.y - frame.minY) / frame.height)
    }
}
