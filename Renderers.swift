import AVFoundation
import CoreVideo
import UIKit

struct DepthFrame {
    let image: UIImage?
    /// Расстояние до центральной точки в метрах (дальномер).
    let centerMeters: Float?
    /// Ближайшее расстояние в зоне слежения (предупреждение о препятствии).
    let nearestMeters: Float?
}

enum RenderStyle: String, CaseIterable, Identifiable {
    case points = "Точки"
    case smooth = "Заливка"
    var id: String { rawValue }
}

/// Область кадра, по которой ищется ближайшее препятствие.
enum AlertZone: String, CaseIterable, Identifiable {
    case center = "Центр"
    case lower  = "Снизу"
    case full   = "Весь кадр"
    var id: String { rawValue }

    var hint: String {
        switch self {
        case .center: return "Только середина экрана — куда наведён прицел"
        case .lower:  return "Нижняя половина — пол и препятствия под ногами"
        case .full:   return "Всё поле зрения сканера"
        }
    }
}

/// Отрисовка карты глубины.
///
/// Режим `.points` — объёмное облако: отсчёты разворачиваются в трёхмерные координаты,
/// по соседям считается нормаль поверхности и освещается виртуальным источником.
/// Камера смотрит строго вперёд, поэтому объём даёт светотень, а не параллакс.
final class DepthRenderer {

    var style: RenderStyle = .points
    var alertZone: AlertZone = .center

    /// Горизонтальный угол обзора объектива в градусах — для обратной проекции.
    var fieldOfView: Float = 70
    /// Сила светотени: 0 — плоско, 1 — контрастный рельеф.
    var relief: Float = 0.75

    private let step = 2

    private var smoothedNear: Float = 0.3
    private var smoothedFar: Float = 4.0
    private var initialized = false

    private let binCount = 160
    private let histMax: Float = 8.0
    private var histogram = [Int](repeating: 0, count: 160)

    // Источник света: сверху-слева-спереди
    private let lightX: Float = -0.45
    private let lightY: Float = -0.55
    private let lightZ: Float = -0.70

    private var canvas: [UInt8] = []
    private var zbuf: [Float] = []
    private var canvasW = 0
    private var canvasH = 0
    private var zoneValues: [Float] = []

    func render(_ depthData: AVDepthData) -> DepthFrame {

        var data = depthData
        if data.depthDataType != kCVPixelFormatType_DepthFloat32 {
            data = data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }

        let buffer = data.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return DepthFrame(image: nil, centerMeters: nil, nearestMeters: nil)
        }

        func depth(_ x: Int, _ y: Int) -> Float {
            base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: Float32.self)[x]
        }

        updateRange(w: w, h: h, sample: depth)
        let centerMeters = medianDepth(cx: w / 2, cy: h / 2, radius: 4,
                                       w: w, h: h, sample: depth)
        let nearestMeters = nearestInZone(w: w, h: h, sample: depth)

        let cg: CGImage?
        switch style {
        case .points: cg = drawPoints(w: w, h: h, sample: depth)
        case .smooth: cg = drawSmooth(w: w, h: h, sample: depth)
        }

        guard let cg else {
            return DepthFrame(image: nil, centerMeters: centerMeters, nearestMeters: nearestMeters)
        }

        let orientation: UIImage.Orientation = (style == .points) ? .up : .right
        return DepthFrame(image: UIImage(cgImage: cg, scale: 1, orientation: orientation),
                          centerMeters: centerMeters,
                          nearestMeters: nearestMeters)
    }

    // MARK: - Поиск ближайшего препятствия

    /// Второй процентиль вместо абсолютного минимума — иначе один шумный
    /// отсчёт заставит рамку моргать без повода.
    private func nearestInZone(w: Int, h: Int, sample: (Int, Int) -> Float) -> Float? {
        // Вертикаль экрана идёт вдоль оси X сенсора: sx = 0 сверху, sx = w снизу.
        let xRange: ClosedRange<Int>
        let yRange: ClosedRange<Int>
        switch alertZone {
        case .center:
            xRange = Int(Float(w) * 0.32)...Int(Float(w) * 0.68)
            yRange = Int(Float(h) * 0.32)...Int(Float(h) * 0.68)
        case .lower:
            xRange = Int(Float(w) * 0.50)...(w - 1)
            yRange = 0...(h - 1)
        case .full:
            xRange = 0...(w - 1)
            yRange = 0...(h - 1)
        }

        zoneValues.removeAll(keepingCapacity: true)
        for x in stride(from: xRange.lowerBound, through: xRange.upperBound, by: 3) {
            for y in stride(from: yRange.lowerBound, through: yRange.upperBound, by: 3) {
                let d = sample(x, y)
                if d.isFinite, d > 0.05, d < histMax { zoneValues.append(d) }
            }
        }
        guard zoneValues.count >= 25 else { return nil }
        zoneValues.sort()
        return zoneValues[max(1, zoneValues.count / 50)]
    }

    // MARK: - Объёмное облако точек

    private func drawPoints(w: Int, h: Int, sample: (Int, Int) -> Float) -> CGImage? {

        let scale: Float = 3.2
        let outH = Int(Float(w) * scale)
        let outW = Int(Float(h) * scale)
        ensureCanvas(outW, outH)

        let hfov = fieldOfView * .pi / 180
        let fx = Float(w) * 0.5 / tan(hfov * 0.5)
        let cx = Float(w) * 0.5
        let cy = Float(h) * 0.5
        let fView = fx * scale

        let near = smoothedNear
        let span = max(smoothedFar - smoothedNear, 0.001)

        let ll = sqrt(lightX*lightX + lightY*lightY + lightZ*lightZ)
        let lx = lightX / ll, ly = lightY / ll, lz = lightZ / ll

        for i in 0..<(outW * outH) {
            canvas[i * 4] = 0; canvas[i * 4 + 1] = 0
            canvas[i * 4 + 2] = 0; canvas[i * 4 + 3] = 255
            zbuf[i] = .greatestFiniteMagnitude
        }

        func unproject(_ x: Int, _ y: Int, _ d: Float) -> (Float, Float, Float) {
            ((Float(x) - cx) * d / fx, (Float(y) - cy) * d / fx, d)
        }

        canvas.withUnsafeMutableBufferPointer { out in
        zbuf.withUnsafeMutableBufferPointer { zb in

            for sy in stride(from: step, to: h - step, by: step) {
                for sx in stride(from: step, to: w - step, by: step) {

                    let d = sample(sx, sy)
                    guard d.isFinite, d > 0.05, d < histMax else { continue }

                    let dR = sample(sx + step, sy), dL = sample(sx - step, sy)
                    let dD = sample(sx, sy + step), dU = sample(sx, sy - step)

                    var shade: Float = 1.0
                    if dR.isFinite, dL.isFinite, dD.isFinite, dU.isFinite,
                       dR > 0.05, dL > 0.05, dD > 0.05, dU > 0.05,
                       abs(dR - dL) < 0.5, abs(dD - dU) < 0.5 {

                        let pR = unproject(sx + step, sy, dR)
                        let pL = unproject(sx - step, sy, dL)
                        let pD = unproject(sx, sy + step, dD)
                        let pU = unproject(sx, sy - step, dU)

                        let ax = pR.0 - pL.0, ay = pR.1 - pL.1, az = pR.2 - pL.2
                        let bx = pD.0 - pU.0, by = pD.1 - pU.1, bz = pD.2 - pU.2

                        var nx = ay * bz - az * by
                        var ny = az * bx - ax * bz
                        var nz = ax * by - ay * bx
                        let nl = sqrt(nx*nx + ny*ny + nz*nz)
                        if nl > 1e-6 {
                            nx /= nl; ny /= nl; nz /= nl
                            let diffuse = max(0, -(nx * lx + ny * ly + nz * lz))
                            shade = (1 - relief) + relief * diffuse
                        }
                    }

                    let ix = Int(Float(h - 1 - sy) * scale)
                    let iy = Int(Float(sx) * scale)
                    guard ix >= 0, ix < outW, iy >= 0, iy < outH else { continue }

                    let radius = max(1, min(6, Int(fView * 0.011 / d)))

                    let t = min(max((d - near) / span, 0), 1)
                    let baseColor = palette(1 - t)
                    let c = (UInt8(min(255, Float(baseColor.0) * shade)),
                             UInt8(min(255, Float(baseColor.1) * shade)),
                             UInt8(min(255, Float(baseColor.2) * shade)))

                    splat(out, zb, outW, outH, ix, iy, radius, d, c)
                }
            }
        }
        }

        return makeImage(canvas, outW, outH, interpolate: false)
    }

    private func splat(_ out: UnsafeMutableBufferPointer<UInt8>,
                       _ zb: UnsafeMutableBufferPointer<Float>,
                       _ outW: Int, _ outH: Int,
                       _ cx: Int, _ cy: Int, _ r: Int, _ z: Float,
                       _ color: (UInt8, UInt8, UInt8)) {
        let y0 = max(cy - r, 0), y1 = min(cy + r, outH - 1)
        let x0 = max(cx - r, 0), x1 = min(cx + r, outW - 1)
        guard y0 <= y1, x0 <= x1 else { return }
        let rr = r * r + r
        for y in y0...y1 {
            let rowBase = y * outW
            for x in x0...x1 {
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy > rr { continue }
                let idx = rowBase + x
                if z >= zb[idx] { continue }
                zb[idx] = z
                let o = idx * 4
                out[o] = color.0; out[o + 1] = color.1; out[o + 2] = color.2
            }
        }
    }

    private func ensureCanvas(_ w: Int, _ h: Int) {
        guard canvasW != w || canvasH != h else { return }
        canvasW = w; canvasH = h
        canvas = [UInt8](repeating: 0, count: w * h * 4)
        zbuf = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
    }

    // MARK: - Плоская заливка

    private func drawSmooth(w: Int, h: Int, sample: (Int, Int) -> Float) -> CGImage? {
        var flat = [UInt8](repeating: 0, count: w * h * 4)
        let near = smoothedNear
        let span = max(smoothedFar - smoothedNear, 0.001)

        flat.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    out[o + 3] = 255
                    let d = sample(x, y)
                    guard d.isFinite, d > 0.05 else { continue }
                    let t = min(max((d - near) / span, 0), 1)
                    let c = palette(1 - t)
                    out[o] = c.0; out[o + 1] = c.1; out[o + 2] = c.2
                }
            }
        }
        return makeImage(flat, w, h, interpolate: true)
    }

    // MARK: - Автодиапазон

    private func updateRange(w: Int, h: Int, sample: (Int, Int) -> Float) {
        for i in 0..<binCount { histogram[i] = 0 }
        var valid = 0
        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: 0, to: w, by: 3) {
                let d = sample(x, y)
                guard d.isFinite, d > 0.05, d < histMax else { continue }
                histogram[min(Int(d / histMax * Float(binCount)), binCount - 1)] += 1
                valid += 1
            }
        }
        guard valid > 200 else { return }

        let loTarget = Int(Float(valid) * 0.03)
        let hiTarget = Int(Float(valid) * 0.97)
        var running = 0
        var near: Float = 0.2
        var far: Float = 5.0
        var gotNear = false
        for bin in 0..<binCount {
            running += histogram[bin]
            let edge = Float(bin) / Float(binCount) * histMax
            if !gotNear, running >= loTarget { near = edge; gotNear = true }
            if running >= hiTarget { far = edge + histMax / Float(binCount); break }
        }
        if far - near < 0.3 { far = near + 0.3 }

        if initialized {
            let a: Float = 0.12
            smoothedNear += (near - smoothedNear) * a
            smoothedFar  += (far  - smoothedFar)  * a
        } else {
            smoothedNear = near; smoothedFar = far
            initialized = true
        }
    }

    // MARK: - Вспомогательное

    private func makeImage(_ pixels: [UInt8], _ w: Int, _ h: Int, interpolate: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: interpolate, intent: .defaultIntent)
    }

    private func medianDepth(cx: Int, cy: Int, radius: Int, w: Int, h: Int,
                             sample: (Int, Int) -> Float) -> Float? {
        var values: [Float] = []
        values.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1))
        for y in max(cy - radius, 0)...min(cy + radius, h - 1) {
            for x in max(cx - radius, 0)...min(cx + radius, w - 1) {
                let d = sample(x, y)
                if d.isFinite, d > 0.05 { values.append(d) }
            }
        }
        guard values.count >= 5 else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    private let stops: [(Float, Float, Float)] = [
        (28, 12, 68), (36, 66, 190), (24, 176, 196),
        (96, 218, 100), (252, 198, 64), (255, 252, 240)
    ]

    private func palette(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Float(stops.count - 1)
        let i = min(Int(scaled), stops.count - 2)
        let f = scaled - Float(i)
        let a = stops[i], b = stops[i + 1]
        return (UInt8(a.0 + (b.0 - a.0) * f),
                UInt8(a.1 + (b.1 - a.1) * f),
                UInt8(a.2 + (b.2 - a.2) * f))
    }
}
