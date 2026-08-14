import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showControls = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = camera.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
            }

            if !camera.status.isEmpty {
                Text(camera.status)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding(32)
            }

            if showControls {
                VStack {
                    Spacer()
                    controls
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Picker("Режим", selection: $camera.mode) {
                ForEach(CameraController.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if !camera.exposureInfo.isEmpty {
                Text(camera.exposureInfo)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
            }

            switch camera.mode {
            case .depth:
                slider("Ближняя граница", value: $camera.minMeters, range: 0.1...2.0,
                       label: String(format: "%.2f м", camera.minMeters))
                slider("Дальняя граница", value: $camera.maxMeters, range: 1.0...8.0,
                       label: String(format: "%.1f м", camera.maxMeters))
                Toggle("Сглаживание дыр", isOn: $camera.depthFiltering)
                    .font(.caption)
                    .tint(.orange)

            case .lowLight:
                slider("Накопление", value: $camera.smoothing, range: 0.03...1.0,
                       label: camera.smoothing >= 0.99 ? "выкл"
                            : String(format: "~%.0f кадров", 1 / camera.smoothing))
                slider("Усиление", value: $camera.gain, range: 0.5...6.0,
                       label: String(format: "×%.1f", camera.gain))
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(12)
    }

    private func slider(_ title: String, value: Binding<Float>,
                        range: ClosedRange<Float>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(label).font(.caption.monospaced()).foregroundStyle(.orange)
            }
            Slider(value: value, in: range).tint(.orange)
        }
    }
}
