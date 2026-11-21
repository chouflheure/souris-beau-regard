import CoreGraphics
import CoreVideo

/// Localise la pupille d'un œil. Renvoie un point normalisé Vision de l'image (origine bas-gauche).
protocol PupilLocator {
    func locate(eye: EyeMeasurement, pixelBuffer: CVPixelBuffer) -> CGPoint?
}

/// Points `leftPupil` / `rightPupil` de Vision. Simple, mais parfois grossier.
struct VisionPupilLocator: PupilLocator {
    func locate(eye: EyeMeasurement, pixelBuffer: CVPixelBuffer) -> CGPoint? {
        eye.visionPupil
    }
}

/// Recadre l'œil dans l'image pleine résolution, passe en niveaux de gris et prend le centre
/// de la zone la plus sombre (seuil adaptatif puis centroïde), à l'intérieur du contour de l'œil.
struct ImagePupilLocator: PupilLocator {
    /// Part des pixels de l'œil considérés comme « pupille » (les plus sombres).
    var darkFraction: Double = 0.12

    func locate(eye: EyeMeasurement, pixelBuffer: CVPixelBuffer) -> CGPoint? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)

        // Boîte de l'œil en pixels, un peu élargie (le contour Vision serre parfois trop).
        let eyeRect = CoordinateSpaces.visionRectToImagePixels(eye.box, imageSize: imageSize)
        let crop = eyeRect
            .insetBy(dx: -eyeRect.width * 0.05, dy: -eyeRect.height * 0.15)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !crop.isNull, crop.width >= 4, crop.height >= 3 else { return nil }
        let cx = Int(crop.minX), cy = Int(crop.minY)
        let cw = Int(crop.width), ch = Int(crop.height)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var gray = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            let row = bytes + (cy + y) * bytesPerRow + cx * 4
            for x in 0..<cw {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                gray[y * cw + x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
            }
        }

        let polygon = eye.contour.map { p -> CGPoint in
            let px = CoordinateSpaces.visionToImagePixels(p, imageSize: imageSize)
            return CGPoint(x: px.x - crop.minX, y: px.y - crop.minY)
        }
        guard let c = DarkCentroid.locate(gray: gray, width: cw, height: ch,
                                          polygon: polygon, darkFraction: darkFraction)
        else { return nil }
        return CoordinateSpaces.imagePixelsToVision(CGPoint(x: c.x + crop.minX, y: c.y + crop.minY),
                                                    imageSize: imageSize)
    }
}

/// Centre de la zone la plus sombre d'une image en niveaux de gris. Logique pure, testée.
enum DarkCentroid {
    /// - Parameters:
    ///   - polygon: contour à l'intérieur duquel chercher (pixels, origine haut-gauche), ou `nil`.
    ///   - darkFraction: part des pixels retenus comme les plus sombres (seuil adaptatif).
    /// - Returns: centroïde pondéré, en pixels (origine haut-gauche, centre des pixels à +0,5).
    static func locate(gray: [UInt8], width: Int, height: Int,
                       polygon: [CGPoint]?, darkFraction: Double) -> CGPoint? {
        let count = width * height
        guard width > 0, height > 0, gray.count == count else { return nil }

        var mask = [Bool](repeating: true, count: count)
        if let polygon, polygon.count >= 3 {
            var inside = 0
            for y in 0..<height {
                for x in 0..<width {
                    let isIn = FaceGeometry.polygon(polygon, contains: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                    mask[y * width + x] = isIn
                    if isIn { inside += 1 }
                }
            }
            // Œil presque fermé : contour trop fin, on cherche dans toute la boîte.
            if inside < 10 { mask = [Bool](repeating: true, count: count) }
        }

        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for i in 0..<count where mask[i] {
            histogram[Int(gray[i])] += 1
            total += 1
        }
        guard total > 0 else { return nil }

        let wanted = max(1, Int((Double(total) * darkFraction).rounded()))
        var cumulative = 0
        var threshold = 255
        for value in 0..<256 {
            cumulative += histogram[value]
            if cumulative >= wanted { threshold = value; break }
        }

        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let v = Int(gray[i])
                guard mask[i], v <= threshold else { continue }
                let weight = Double(threshold - v + 1)
                sx += (Double(x) + 0.5) * weight
                sy += (Double(y) + 0.5) * weight
                sw += weight
            }
        }
        guard sw > 0 else { return nil }
        return CGPoint(x: sx / sw, y: sy / sw)
    }
}
