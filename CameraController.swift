import AVFoundation
import CoreVideo
import UIKit
import Combine

/// Поток глубины с LiDAR напрямую через AVFoundation, минуя ARKit.
/// Сканер светит собственным ИК-лучом, поэтому внешний свет не нужен.
final class CameraController: NSObject, ObservableObject {

    // MARK: - Выход

    @Published var image: UIImage?
    @Published var centerMeters: Float?
    @Published var nearestMeters: Float?
    /// Сработало ли предупреждение о препятствии (с гистерезисом).
    @Published var alerting: Bool = false
    @Published var status: String = ""

    // MARK: - Настройки

    @Published var style: RenderStyle = .points {
        didSet { let s = style; queue.async { self.renderer.style = s } }
    }
    @Published var depthFiltering: Bool = true {
        didSet { let f = depthFiltering; queue.async { self.depthOutput.isFilteringEnabled = f } }
    }
    @Published var relief: Float = 0.75 {
        didSet { let r = relief; queue.async { self.renderer.relief = r } }
    }

    @Published var alertEnabled: Bool = true
    /// Порог срабатывания в метрах.
    @Published var alertThreshold: Float = 0.5
    @Published var alertZone: AlertZone = .center {
        didSet { let z = alertZone; queue.async { self.renderer.alertZone = z } }
    }
    @Published var hapticsEnabled: Bool = true

    // MARK: - Внутреннее

    let session = AVCaptureSession()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "nightsight.capture", qos: .userInitiated)
    private let renderer = DepthRenderer()
    private var device: AVCaptureDevice?

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var lastHaptic = Date.distantPast

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.status = "Нет доступа к камере" }
                return
            }
            self.queue.async {
                self.configure()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
        haptic.prepare()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera,
                                                   for: .video,
                                                   position: .back) else {
            DispatchQueue.main.async {
                self.status = "LiDAR не найден.\nНужен iPhone Pro (12 Pro и новее)."
            }
            return
        }
        self.device = device
        session.sessionPreset = .inputPriority

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)
        } catch {
            DispatchQueue.main.async { self.status = "Ошибка камеры: \(error.localizedDescription)" }
            return
        }

        // Видеокадры не читаем, но выход держим: без активного видеотракта
        // устройство не отдаёт глубину.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
        depthOutput.isFilteringEnabled = depthFiltering
        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.connection(with: .depthData)?.isEnabled = true
        depthOutput.setDelegate(self, callbackQueue: queue)

        renderer.style = style
        renderer.relief = relief
        renderer.alertZone = alertZone
        selectBestFormat(device)
        renderer.fieldOfView = device.activeFormat.videoFieldOfView

        DispatchQueue.main.async { self.status = "" }
    }

    private func selectBestFormat(_ device: AVCaptureDevice) {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }

        let candidates = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        guard let format = candidates.max(by: { a, b in
            let da = a.supportedDepthDataFormats.map { Int(dims($0).width) * Int(dims($0).height) }.max() ?? 0
            let db = b.supportedDepthDataFormats.map { Int(dims($0).width) * Int(dims($0).height) }.max() ?? 0
            if da != db { return da < db }
            return Int(dims(a).width) > Int(dims(b).width)
        }) else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format

            let depthFormats = format.supportedDepthDataFormats
            let float16 = depthFormats.filter {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
            }
            let pool = float16.isEmpty ? depthFormats : float16
            device.activeDepthDataFormat = pool.max {
                dims($0).width * dims($0).height < dims($1).width * dims($1).height
            }

            let target = CMTime(value: 1, timescale: 30)
            if let range = format.videoSupportedFrameRateRanges.first,
               CMTimeCompare(target, range.minFrameDuration) >= 0,
               CMTimeCompare(target, range.maxFrameDuration) <= 0 {
                device.activeVideoMinFrameDuration = target
            }

            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.status = "Ошибка формата: \(error.localizedDescription)" }
        }
    }

    // MARK: - Логика предупреждения

    /// Гистерезис: включаемся на пороге, отпускаем на 10 см дальше,
    /// иначе на границе рамка дёргается по нескольку раз в секунду.
    private func updateAlert(_ nearest: Float?) {
        guard alertEnabled, let d = nearest else {
            if alerting { alerting = false }
            return
        }
        if alerting {
            if d > alertThreshold + 0.10 { alerting = false }
        } else {
            if d <= alertThreshold { alerting = true }
        }

        guard alerting, hapticsEnabled else { return }

        // Чем ближе объект, тем чаще стук: от 0.6 с у порога до 0.09 с вплотную
        let ratio = min(max(d / max(alertThreshold, 0.01), 0), 1)
        let interval = 0.09 + Double(ratio) * 0.51
        if Date().timeIntervalSince(lastHaptic) >= interval {
            haptic.impactOccurred(intensity: CGFloat(1.0 - ratio * 0.5))
            haptic.prepare()
            lastHaptic = Date()
        }
    }
}

extension CameraController: AVCaptureDepthDataOutputDelegate {

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection) {
        let frame = renderer.render(depthData)
        DispatchQueue.main.async {
            self.image = frame.image
            self.centerMeters = frame.centerMeters
            self.nearestMeters = frame.nearestMeters
            self.updateAlert(frame.nearestMeters)
        }
    }
}
