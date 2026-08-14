import AVFoundation
import CoreVideo
import UIKit

// MARK: - Depth → false color

enum DepthColorMapper {

    /// Переводит карту глубины в цветное изображение.
    /// Ближние точки — тёплые/яркие, дальние — холодные, невалидные (NaN) — чёрные.
    static func image(from depthData: AVDepthData, minMeters: Float, maxMeters: Float) -> UIImage? {

        // Приводим к метрам во Float32. Если пришла диспаритетная карта,
        // converting() сам сделает 1/x пересчёт.
        var data = depthData
        if data.depthDataType != kCVPixelFormatType_DepthFloat32 {
            data = data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }

        let buffer = data.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let span = max(maxMeters - minMeters, 0.001)

        rgba.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    let d = row[x]
                    let o = (y * width + x) * 4
                    out[o + 3] = 255
                    guard d.isFinite, d > 0 else { continue }   // NaN / 0 = нет отражения
                    let t = min(max((d - minMeters) / span, 0), 1)
                    let c = ramp(1 - t)                          // ближе = ярче
                    out[o] = c.0; out[o + 1] = c.1; out[o + 2] = c.2
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: width,
                               height: height,
                               bitsPerComponent: 8,
                               bitsPerPixel: 32,
                               bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }

        // Буфер приходит в ориентации сенсора — доворачиваем под портрет.
        return UIImage(cgImage: cg, scale: 1, orientation: .right)
    }

    /// Пятиточечная палитра: тёмно-синий → синий → зелёный → жёлтый → белый.
    private static let stops: [(Float, Float, Float)] = [
        (4, 8, 40), (20, 70, 190), (30, 190, 140), (250, 210, 60), (255, 255, 245)
    ]

    private static func ramp(_ t: Float) -> (UInt8, UInt8, UInt8) {
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

// MARK: - Temporal averaging (шумодав для длинной выдержки)

/// Экспоненциальное скользящее среднее по кадрам.
/// Шум сенсора некоррелирован между кадрами, сигнал — коррелирован,
/// поэтому усреднение поднимает SNR примерно как √N.
final class FrameAccumulator {

    var alpha: Float = 0.25   // 1.0 = без накопления, 0.05 = очень плавно
    var gain: Float = 1.0

    private var acc: [Float] = []
    private var width = 0
    private var height = 0
    private let lock = NSLock()

    func reset() {
        lock.lock(); acc = []; width = 0; height = 0; lock.unlock()
    }

    func add(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        lock.lock()
        if acc.count != w * h * 3 || width != w || height != h {
            acc = [Float](repeating: 0, count: w * h * 3)
            width = w; height = h
            // Первый кадр кладём как есть, иначе экспозиция «выплывает» из чёрного.
            fill(base: base, rowBytes: rowBytes, w: w, h: h, alpha: 1.0)
        } else {
            fill(base: base, rowBytes: rowBytes, w: w, h: h, alpha: alpha)
        }

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let g = gain
        acc.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    dst[i * 4]     = clamp8(src[i * 3]     * g)
                    dst[i * 4 + 1] = clamp8(src[i * 3 + 1] * g)
                    dst[i * 4 + 2] = clamp8(src[i * 3 + 2] * g)
                    dst[i * 4 + 3] = 255
                }
            }
        }
        lock.unlock()

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent) else { return nil }

        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// BGRA → накопитель в порядке RGB.
    private func fill(base: UnsafeMutableRawPointer, rowBytes: Int, w: Int, h: Int, alpha: Float) {
        let inv = 1 - alpha
        acc.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let s = x * 4
                    let d = (y * w + x) * 3
                    dst[d]     = dst[d]     * inv + Float(row[s + 2]) * alpha   // R
                    dst[d + 1] = dst[d + 1] * inv + Float(row[s + 1]) * alpha   // G
                    dst[d + 2] = dst[d + 2] * inv + Float(row[s])     * alpha   // B
                }
            }
        }
    }

    private func clamp8(_ v: Float) -> UInt8 {
        UInt8(min(max(v, 0), 255))
    }
}
