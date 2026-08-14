import AVFoundation
import CoreVideo
import UIKit

struct DepthFrame {
    let image: UIImage?
    /// Расстояние до центральной точки в метрах, nil — нет валидных измерений.
    let centerMeters: Float?
}

enum RenderStyle: String, CaseIterable, Identifiable {
    case points = "Точки"
    case smooth = "Заливка"
    var id: String { rawValue }
}

/// Отрисовка карты глубины. Диапазон подбирается автоматически по перцентилям сцены
/// и сглаживается между кадрами, чтобы картинка не «дышала» при малейшем движении.
final class DepthRenderer {

    var style: RenderStyle = .points

    /// Во сколько раз выходная картинка крупнее карты глубины (режим точек).
    private let upscale = 5
    /// Берём каждый N-й отсчёт — иначе точки сливаются в сплошную заливку.
    private let step = 2

    private var smoothedNear: Float = 0.3
    private var smoothedFar: Float = 4.0
    private var initialized = false

    private let binCount = 160
    private let histMax: Float = 8.0
    private var histogram = [Int](repeating: 0, count: 160)

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
            return DepthFrame(image: nil, centerMeters: nil)
        }

        func depth(_ x: Int, _ y: Int) -> Float {
            base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: Float32.self)[x]
        }

        updateRange(w: w, h: h, sample: depth)

        let near = smoothedNear
        let span = max(smoothedFar - smoothedNear, 0.001)

        let centerMeters = medianDepth(cx: w / 2, cy: h / 2, radius: 4,
                                       w: w, h: h, sample: depth)

        let cg: CGImage?
        switch style {
        case .points: cg = drawPoints(w: w, h: h, near: near, span: span, sample: depth)
        case .smooth: cg = drawSmooth(w: w, h: h, near: near, span: span, sample: depth)
        }

        guard let cg else { return DepthFrame(image: nil, centerMeters: centerMeters) }
        return DepthFrame(image: UIImage(cgImage: cg, scale: 1, orientation: .right),
                          centerMeters: centerMeters)
    }

    // MARK: - Автодиапазон

    private func updateRange(w: Int, h: Int, sample: (Int, Int) -> Float) {
        for i in 0..<binCount { histogram[i] = 0 }
        var valid = 0
        let scanStep = 3
        for y in stride(from: 0, to: h, by: scanStep) {
            for x in stride(from: 0, to: w, by: scanStep) {
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

    // MARK: - Стиль «точки»

    private func drawPoints(w: Int, h: Int, near: Float, span: Float,
                            sample: (Int, Int) -> Float) -> CGImage? {
        let outW = w * upscale / step
        let outH = h * upscale / step
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)

        rgba.withUnsafeMutableBufferPointer { out in
            for i in 0..<(outW * outH) { out[i * 4 + 3] = 255 }

            var oy = 0
            for y in stride(from: 0, to: h, by: step) {
                var ox = 0
                for x in stride(from: 0, to: w, by: step) {
                    defer { ox += upscale }
                    let d = sample(x, y)
                    guard d.isFinite, d > 0.05 else { continue }
                    let t = min(max((d - near) / span, 0), 1)
                    let c = palette(1 - t)
                    let size = 2 + Int((1 - t) * 2.2)   // ближе — крупнее
                    dot(out, outW, outH, ox + upscale / 2, oy + upscale / 2, size, c)
                }
                oy += upscale
            }
        }
        return makeImage(rgba, outW, outH, interpolate: false)
    }

    // MARK: - Стиль «заливка»

    private func drawSmooth(w: Int, h: Int, near: Float, span: Float,
                            sample: (Int, Int) -> Float) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        rgba.withUnsafeMutableBufferPointer { out in
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
        return makeImage(rgba, w, h, interpolate: true)
    }

    // MARK: - Вспомогательное

    private func makeImage(_ rgba: [UInt8], _ w: Int, _ h: Int, interpolate: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: interpolate, intent: .defaultIntent)
    }

    private func dot(_ out: UnsafeMutableBufferPointer<UInt8>,
                     _ w: Int, _ h: Int, _ cx: Int, _ cy: Int,
                     _ size: Int, _ color: (UInt8, UInt8, UInt8)) {
        let r = size / 2
        let y0 = max(cy - r, 0), y1 = min(cy + r, h - 1)
        let x0 = max(cx - r, 0), x1 = min(cx + r, w - 1)
        guard y0 <= y1, x0 <= x1 else { return }
        for y in y0...y1 {
            let rowBase = y * w
            for x in x0...x1 {
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy > r * r + r { continue }
                let o = (rowBase + x) * 4
                out[o] = color.0; out[o + 1] = color.1; out[o + 2] = color.2
            }
        }
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
        (28, 12, 68), (36, 66, 190), (24, 176, 190),
        (90, 214, 96), (250, 196, 62), (255, 250, 235)
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
