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

/// Recadre l'œil dans l'image pleine résolution, passe en niveaux de gris et cherche l'iris :
/// le carré de la taille de l'iris le plus sombre en moyenne (les cils et l'ombre de la paupière,
/// fins, ne l'attirent pas), puis le centre de sa partie la plus sombre (la pupille).
struct ImagePupilLocator: PupilLocator {
    /// Côté du carré de recherche, en fraction de la largeur de l'œil (coin à coin).
    /// L'iris mesure environ 40 % de cette largeur ; un carré un peu plus petit tient dedans.
    var irisFraction: Double = 0.3

    /// Le contour de Vision est souvent trop petit et trop bas (il coupe le haut de l'iris) :
    /// la zone de recherche est le contour agrandi autour de son centre, surtout en hauteur.
    static let maskScaleX: CGFloat = 1.15
    static let maskScaleY: CGFloat = 1.8

    func locate(eye: EyeMeasurement, pixelBuffer: CVPixelBuffer) -> CGPoint? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)

        // Boîte de l'œil en pixels, un peu élargie (le contour Vision serre parfois trop).
        let eyeRect = CoordinateSpaces.visionRectToImagePixels(eye.box, imageSize: imageSize)
        let crop = eyeRect
            .insetBy(dx: -eyeRect.width * 0.15, dy: -eyeRect.height * 0.6)
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
        let eyeWidth = GazeFeatures.corners(of: polygon).map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) } ?? crop.width
        let side = max(3, Int((Double(eyeWidth) * irisFraction).rounded()))
        // Noyau du filtre : ~14 % de la largeur de l'œil, impair, au moins 3.
        let kernel = max(3, Int((Double(eyeWidth) * 0.14).rounded()) | 1)
        guard let c = DarkCentroid.locateIrisRobust(gray: gray, width: cw, height: ch,
                                                    polygon: polygon, boxSide: side,
                                                    maskScaleX: Self.maskScaleX, maskScaleY: Self.maskScaleY,
                                                    kernel: kernel)
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

extension DarkCentroid {
    /// Centre de l'iris (puis de la pupille) dans une image en niveaux de gris.
    ///
    /// 1. Masque : le contour de l'œil mis à l'échelle autour de son centre (`maskScaleX/Y` ;
    ///    agrandi en pratique, car le contour de Vision coupe souvent le haut de l'iris).
    /// 2. Le carré de côté `boxSide` dont les pixels du masque sont les plus sombres en moyenne
    ///    (images intégrales : rapide) ; au moins la moitié du carré doit être dans l'œil.
    /// 3. Dans une fenêtre un peu plus grande autour de ce carré, centroïde pondéré des pixels sous
    ///    `min + 40 % × (moyenne − min)` : la pupille si elle est visible, sinon le cœur de l'iris.
    /// - Returns: pixels de l'image recadrée (origine haut-gauche, centre des pixels à +0,5).
    static func locateIris(gray: [UInt8], width: Int, height: Int,
                           polygon: [CGPoint]?, boxSide: Int,
                           maskScaleX: CGFloat = 0.9, maskScaleY: CGFloat = 0.9) -> CGPoint? {
        let count = width * height
        guard width > 0, height > 0, gray.count == count else { return nil }

        var mask = [Bool](repeating: true, count: count)
        if let polygon, polygon.count >= 3 {
            let n = CGFloat(polygon.count)
            let c = CGPoint(x: polygon.reduce(0) { $0 + $1.x } / n, y: polygon.reduce(0) { $0 + $1.y } / n)
            let shrunk = polygon.map { CGPoint(x: c.x + ($0.x - c.x) * maskScaleX, y: c.y + ($0.y - c.y) * maskScaleY) }
            var inside = 0
            for y in 0..<height {
                for x in 0..<width {
                    let isIn = FaceGeometry.polygon(shrunk, contains: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                    mask[y * width + x] = isIn
                    if isIn { inside += 1 }
                }
            }
            if inside < 10 { mask = [Bool](repeating: true, count: count) }
        }

        // Images intégrales des niveaux de gris masqués et du nombre de pixels masqués.
        let stride = width + 1
        var sum = [Double](repeating: 0, count: stride * (height + 1))
        var cnt = [Int](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            var rowCount = 0
            for x in 0..<width {
                let i = y * width + x
                if mask[i] { rowSum += Double(gray[i]); rowCount += 1 }
                sum[(y + 1) * stride + x + 1] = sum[y * stride + x + 1] + rowSum
                cnt[(y + 1) * stride + x + 1] = cnt[y * stride + x + 1] + rowCount
            }
        }
        func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (sum: Double, count: Int) {
            let s = sum[y1 * stride + x1] - sum[y0 * stride + x1] - sum[y1 * stride + x0] + sum[y0 * stride + x0]
            let c = cnt[y1 * stride + x1] - cnt[y0 * stride + x1] - cnt[y1 * stride + x0] + cnt[y0 * stride + x0]
            return (s, c)
        }

        let side = max(1, min(boxSide, width, height))
        var best: (mean: Double, x: Int, y: Int)?
        for y0 in 0...(height - side) {
            for x0 in 0...(width - side) {
                let b = box(x0, y0, x0 + side, y0 + side)
                guard b.count * 2 >= side * side, b.count > 0 else { continue }
                let mean = b.sum / Double(b.count)
                if best == nil || mean < best!.mean { best = (mean, x0, y0) }
            }
        }
        guard let best else { return nil }

        let centerX = Double(best.x) + Double(side) / 2
        let centerY = Double(best.y) + Double(side) / 2
        let half = max(1, Int((Double(side) * 0.8).rounded()))
        let wx0 = max(0, Int(centerX) - half), wx1 = min(width, Int(centerX) + half)
        let wy0 = max(0, Int(centerY) - half), wy1 = min(height, Int(centerY) + half)
        var values: [Int] = []
        for y in wy0..<wy1 { for x in wx0..<wx1 where mask[y * width + x] { values.append(Int(gray[y * width + x])) } }
        guard let minValue = values.min() else { return CGPoint(x: centerX, y: centerY) }
        let meanValue = Double(values.reduce(0, +)) / Double(values.count)
        let threshold = Double(minValue) + 0.4 * (meanValue - Double(minValue))

        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in wy0..<wy1 {
            for x in wx0..<wx1 {
                let i = y * width + x
                let v = Double(gray[i])
                guard mask[i], v <= threshold else { continue }
                let w = threshold - v + 1
                sx += (Double(x) + 0.5) * w
                sy += (Double(y) + 0.5) * w
                sw += w
            }
        }
        return sw > 0 ? CGPoint(x: sx / sw, y: sy / sw) : CGPoint(x: centerX, y: centerY)
    }
}

// MARK: - Recherche robuste : reflets, cils et ombre de paupière

extension DarkCentroid {
    /// Filtre min ou max sur un carré de côté `kernel` (bords : fenêtre tronquée), séparable.
    static func morphology(_ g: [UInt8], width: Int, height: Int, kernel: Int, takeMax: Bool) -> [UInt8] {
        let r = max(kernel / 2, 0)
        guard r > 0, g.count == width * height else { return g }
        var rows = [UInt8](repeating: 0, count: g.count)
        for y in 0..<height {
            for x in 0..<width {
                var v = g[y * width + x]
                for xx in max(0, x - r)...min(width - 1, x + r) {
                    let p = g[y * width + xx]
                    v = takeMax ? max(v, p) : min(v, p)
                }
                rows[y * width + x] = v
            }
        }
        var out = [UInt8](repeating: 0, count: g.count)
        for y in 0..<height {
            for x in 0..<width {
                var v = rows[y * width + x]
                for yy in max(0, y - r)...min(height - 1, y + r) {
                    let p = rows[yy * width + x]
                    v = takeMax ? max(v, p) : min(v, p)
                }
                out[y * width + x] = v
            }
        }
        return out
    }

    /// Fermeture puis ouverture : efface le sombre fin (cils, pupille) puis le clair petit (reflets).
    /// Il ne reste que l'iris, tache sombre uniforme.
    static func closeOpen(_ g: [UInt8], width: Int, height: Int, kernel: Int) -> [UInt8] {
        let closed = morphology(morphology(g, width: width, height: height, kernel: kernel, takeMax: true),
                                width: width, height: height, kernel: kernel, takeMax: false)
        return morphology(morphology(closed, width: width, height: height, kernel: kernel, takeMax: false),
                          width: width, height: height, kernel: kernel, takeMax: true)
    }

    /// Une corde de l'iris : ligne `y`, bord gauche et bord droit (pixels).
    struct Chord: Equatable {
        var y: Double
        var left: Double
        var right: Double
    }

    /// Bords gauche (clair → sombre) et droit (sombre → clair) de l'iris sur chaque ligne proche du centre.
    static func irisChords(_ f: [UInt8], width: Int, height: Int, center: CGPoint, side: Int,
                           minContrast: Int = 12) -> [Chord] {
        let cx = Int(center.x), s = Double(side)
        let lo = max(1, Int(Double(center.x) - 1.3 * s)), hi = min(width - 2, Int(Double(center.x) + 1.3 * s))
        guard lo <= cx, cx <= hi else { return [] }
        let y0 = max(1, Int(Double(center.y) - s)), y1 = min(height - 1, Int(Double(center.y) + s) + 1)
        guard y0 < y1 else { return [] }
        var chords: [Chord] = []
        for y in y0..<y1 {
            func gradient(_ x: Int) -> Int {
                Int(f[y * width + min(width - 1, x + 1)]) - Int(f[y * width + max(0, x - 1)])
            }
            var left = lo, right = cx
            for x in lo...cx where gradient(x) < gradient(left) { left = x }
            for x in cx...hi where gradient(x) > gradient(right) { right = x }
            guard -gradient(left) >= minContrast, gradient(right) >= minContrast else { continue }
            chords.append(Chord(y: Double(y) + 0.5, left: Double(left), right: Double(right + 1)))
        }
        return chords
    }

    /// Centre du cercle passant par les cordes (moindres carrés sur (L/2)² + y² = 2·y·cy + c) ;
    /// marche même si la paupière cache le haut de l'iris.
    static func circleCenter(from chords: [Chord]) -> CGPoint? {
        guard chords.count >= 3 else { return nil }
        var syy = 0.0, sy = 0.0, sb = 0.0, syb = 0.0
        let n = Double(chords.count)
        for c in chords {
            let a = 2 * c.y
            let half = (c.right - c.left) / 2
            let b = half * half + c.y * c.y
            syy += a * a; sy += a; sb += b; syb += a * b
        }
        let det = syy * n - sy * sy
        guard abs(det) > 1e-9 else { return nil }
        let cy = (syb * n - sy * sb) / det
        let cx = Stats.median(chords.map { ($0.left + $0.right) / 2 })
        return CGPoint(x: cx, y: cy)
    }

    /// Iris robuste : filtre fermeture/ouverture, recherche du carré sombre, puis centre du cercle
    /// ajusté sur les bords de l'iris (si on en trouve assez, et s'il reste proche).
    static func locateIrisRobust(gray: [UInt8], width: Int, height: Int, polygon: [CGPoint]?,
                                 boxSide: Int, maskScaleX: CGFloat, maskScaleY: CGFloat,
                                 kernel: Int) -> CGPoint? {
        guard gray.count == width * height else { return nil }
        let filtered = closeOpen(gray, width: width, height: height, kernel: kernel)
        guard let rough = locateIris(gray: filtered, width: width, height: height, polygon: polygon,
                                     boxSide: boxSide, maskScaleX: maskScaleX, maskScaleY: maskScaleY)
        else { return nil }
        let chords = irisChords(filtered, width: width, height: height, center: rough, side: boxSide)
        guard let fit = circleCenter(from: chords), fit.x.isFinite, fit.y.isFinite,
              hypot(fit.x - rough.x, fit.y - rough.y) <= CGFloat(boxSide) else { return rough }
        return fit
    }
}
