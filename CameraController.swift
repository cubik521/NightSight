import AVFoundation
import CoreVideo
import UIKit
import Combine

/// Управляет AVCaptureSession в двух режимах:
///  - .depth    — сырые данные LiDAR (работают в полной темноте, свет не нужен)
///  - .lowLight — максимальная выдержка + ISO + temporal averaging по кадрам RGB
final class CameraController: NSObject, ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case depth = "LiDAR"
        case lowLight = "Long exposure"
        var id: String { rawValue }
    }

    // MARK: - Published state (UI)

    @Published var image: UIImage?
    @Published var status: String = "Инициализация…"
    @Published var exposureInfo: String = ""

    @Published var mode: Mode = .depth {
        didSet { queue.async { [weak self] in self?.applyMode() } }
    }
    @Published var minMeters: Float = 0.2 { didSet { syncRange() } }
    @Published var maxMeters: Float = 5.0 { didSet { syncRange() } }
    @Published var smoothing: Float = 0.25 { didSet { accumulator.alpha = smoothing } }
    @Published var gain: Float = 1.0 { didSet { accumulator.gain = gain } }
    @Published var depthFiltering: Bool = true {
        didSet { queue.async { [weak self] in self?.depthOutput.isFilteringEnabled = self?.depthFiltering ?? true } }
    }

    // MARK: - Capture stack

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let queue = DispatchQueue(label: "nightsight.capture", qos: .userInitiated)

    private var device: AVCaptureDevice?
    private let accumulator = FrameAccumulator()

    // Копии состояния, читаемые из capture-очереди без обращения к @Published
    private var currentMode: Mode = .depth
    private var rangeMin: Float = 0.2
    private var rangeMax: Float = 5.0

    // MARK: - Lifecycle

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
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Configuration

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // На Pro-моделях это широкоугольная камера, физически связанная с LiDAR-сканером.
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera,
                                                   for: .video,
                                                   position: .back) else {
            DispatchQueue.main.async {
                self.status = "LiDAR не найден. Нужен iPhone Pro / Pro Max (12 Pro и новее)."
            }
            return
        }
        self.device = device

        session.sessionPreset = .inputPriority   // формат выбираем вручную

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async { self.status = "Не удалось добавить вход камеры" }
                return
            }
            session.addInput(input)
        } catch {
            DispatchQueue.main.async { self.status = "Ошибка входа: \(error.localizedDescription)" }
            return
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
        depthOutput.isFilteringEnabled = depthFiltering
        depthOutput.connection(with: .depthData)?.isEnabled = true

        // Видео-выход держим в портрете; depth-буфер поворачиваем сами при отрисовке.
        videoOutput.connection(with: .video)?.videoOrientation = .portrait

        selectFormat(for: currentMode)
        applyExposure(for: currentMode)

        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer?.setDelegate(self, queue: queue)

        DispatchQueue.main.async { self.status = "" }
    }

    /// Выбирает формат камеры. Для depth — максимальное разрешение карты глубины,
    /// для low-light — формат с наибольшей допустимой выдержкой.
    private func selectFormat(for mode: Mode) {
        guard let device else { return }

        let candidates = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        guard !candidates.isEmpty else {
            DispatchQueue.main.async { self.status = "Нет форматов с поддержкой глубины" }
            return
        }

        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }

        let chosen: AVCaptureDevice.Format?
        switch mode {
        case .depth:
            // Максимальное разрешение depth-карты; при равенстве — меньший RGB-кадр (меньше нагрузка).
            chosen = candidates.max { a, b in
                let da = a.supportedDepthDataFormats.map { Int(dims($0).width) }.max() ?? 0
                let db = b.supportedDepthDataFormats.map { Int(dims($0).width) }.max() ?? 0
                if da != db { return da < db }
                return Int(dims(a).width) > Int(dims(b).width)
            }
        case .lowLight:
            chosen = candidates.max { a, b in
                let ea = CMTimeGetSeconds(a.maxExposureDuration)
                let eb = CMTimeGetSeconds(b.maxExposureDuration)
                if abs(ea - eb) > 0.0001 { return ea < eb }
                return a.maxISO < b.maxISO
            }
        }

        guard let format = chosen else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format

            // Предпочитаем Float16 — нативный тип LiDAR, конверсия дешевле.
            let depthFormats = format.supportedDepthDataFormats
            let float16 = depthFormats.filter {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
            }
            let pool = float16.isEmpty ? depthFormats : float16
            device.activeDepthDataFormat = pool.max {
                dims($0).width * dims($0).height < dims($1).width * dims($1).height
            }
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.status = "Ошибка формата: \(error.localizedDescription)" }
        }
    }

    /// Ручная экспозиция для low-light, авто — для depth.
    private func applyExposure(for mode: Mode) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            switch mode {
            case .depth:
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.activeVideoMinFrameDuration = device.activeFormat.videoSupportedFrameRateRanges
                    .first?.minFrameDuration ?? CMTime(value: 1, timescale: 30)
                DispatchQueue.main.async { self.exposureInfo = "" }

            case .lowLight:
                let format = device.activeFormat
                let duration = format.maxExposureDuration
                let iso = min(format.maxISO, device.activeFormat.maxISO)

                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                // Частота кадров не может быть выше, чем позволяет выдержка.
                let ranges = format.videoSupportedFrameRateRanges
                let minAllowed = ranges.first?.minFrameDuration ?? CMTime(value: 1, timescale: 30)
                let maxAllowed = ranges.first?.maxFrameDuration ?? CMTime(value: 1, timescale: 2)
                var target = duration
                if CMTimeCompare(target, minAllowed) < 0 { target = minAllowed }
                if CMTimeCompare(target, maxAllowed) > 0 { target = maxAllowed }
                device.activeVideoMinFrameDuration = target

                let secs = CMTimeGetSeconds(duration)
                let fps = 1.0 / max(CMTimeGetSeconds(target), 0.0001)
                DispatchQueue.main.async {
                    self.exposureInfo = String(format: "выдержка 1/%.0f с · ISO %.0f · %.1f fps",
                                               1.0 / max(secs, 0.0001), iso, fps)
                }
            }
        } catch {
            DispatchQueue.main.async { self.status = "Ошибка экспозиции: \(error.localizedDescription)" }
        }
    }

    private func applyMode() {
        let newMode = DispatchQueue.main.sync { self.mode }
        currentMode = newMode
        accumulator.reset()

        session.beginConfiguration()
        selectFormat(for: newMode)
        session.commitConfiguration()
        applyExposure(for: newMode)
    }

    private func syncRange() {
        let lo = minMeters, hi = maxMeters
        queue.async { [weak self] in
            self?.rangeMin = lo
            self?.rangeMax = hi
        }
    }
}

// MARK: - Frame delivery

extension CameraController: AVCaptureDataOutputSynchronizerDelegate {

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {

        switch currentMode {

        case .depth:
            guard let sync = collection.synchronizedData(for: depthOutput)
                    as? AVCaptureSynchronizedDepthData,
                  !sync.depthDataWasDropped else { return }

            let rendered = DepthColorMapper.image(from: sync.depthData,
                                                  minMeters: rangeMin,
                                                  maxMeters: rangeMax)
            DispatchQueue.main.async { self.image = rendered }

        case .lowLight:
            guard let sync = collection.synchronizedData(for: videoOutput)
                    as? AVCaptureSynchronizedSampleBufferData,
                  !sync.sampleBufferWasDropped,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sync.sampleBuffer) else { return }

            let rendered = accumulator.add(pixelBuffer)
            DispatchQueue.main.async { self.image = rendered }
        }
    }
}
