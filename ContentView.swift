import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var rangefinder = false
    @State private var showPanel = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = camera.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showPanel.toggle() }
                        }
                }

                if !camera.status.isEmpty {
                    Text(camera.status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                        .padding(32)
                }

                if rangefinder { crosshair }

                VStack {
                    Spacer()
                    if showPanel {
                        panel.transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Панель управления

    private var panel: some View {
        HStack(spacing: 14) {
            VStack(spacing: 10) {
                Picker("Стиль", selection: $camera.style) {
                    ForEach(RenderStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Сглаживание дыр", isOn: $camera.depthFiltering)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .tint(.orange)
            }

            rangefinderButton
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 20)
    }

    // MARK: - Прицел

    private var crosshair: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(.white)
                    .frame(width: 3, height: 3)
                ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { angle in
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 1.5, height: 7)
                        .offset(y: -20)
                        .rotationEffect(.degrees(angle))
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 3)

            Text(readout)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .offset(y: -40)
    }

    private var readout: String {
        guard let d = camera.centerMeters else { return "— — —" }
        return d < 1
            ? String(format: "%.0f см", d * 100)
            : String(format: "%.2f м", d)
    }

    // MARK: - Кнопка дальномера

    private var rangefinderButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { rangefinder.toggle() }
        } label: {
            Image(systemName: rangefinder ? "scope" : "ruler")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(rangefinder ? .black : .white)
                .frame(width: 54, height: 54)
                .background(
                    Circle().fill(rangefinder ? AnyShapeStyle(.white)
                                              : AnyShapeStyle(.white.opacity(0.15)))
                )
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }
}
