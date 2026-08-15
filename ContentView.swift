import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var rangefinder = false
    @State private var showPanel = true
    @State private var showSettings = false
    @State private var pulse = false

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

                if camera.alerting { alertBorder }

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
                    if camera.alerting { proximityBadge.padding(.top, 8) }
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
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Панель управления

    private var panel: some View {
        HStack(alignment: .top, spacing: 12) {

            VStack(spacing: 10) {
                Picker("Стиль", selection: $camera.style) {
                    ForEach(RenderStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if camera.style == .points {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Рельеф").font(.caption)
                            Spacer()
                            Text(String(format: "%.0f%%", camera.relief * 100))
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Slider(value: $camera.relief, in: 0...1).tint(.orange)
                    }
                }

                Toggle("Сглаживание дыр", isOn: $camera.depthFiltering)
                    .font(.caption)
                    .tint(.orange)
            }
            .foregroundStyle(.white)

            VStack(spacing: 10) {
                circleButton(icon: rangefinder ? "scope" : "ruler", active: rangefinder) {
                    withAnimation(.easeInOut(duration: 0.15)) { rangefinder.toggle() }
                }
                circleButton(icon: "slider.horizontal.3", active: false) {
                    showSettings = true
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 20)
    }

    private func circleButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? .black : .white)
                .frame(width: 46, height: 46)
                .background(
                    Circle().fill(active ? AnyShapeStyle(.white)
                                         : AnyShapeStyle(.white.opacity(0.15)))
                )
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }

    // MARK: - Предупреждение

    private var alertBorder: some View {
        RoundedRectangle(cornerRadius: 44)
            .strokeBorder(Color.red, lineWidth: 7)
            .shadow(color: .red.opacity(0.85), radius: 22)
            .opacity(pulse ? 0.45 : 1.0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onDisappear { pulse = false }
    }

    private var proximityBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(camera.nearestMeters.map { String(format: "%.0f см", $0 * 100) } ?? "близко")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.red.opacity(0.85), in: Capsule())
        .allowsHitTesting(false)
    }

    // MARK: - Прицел

    private var crosshair: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                Circle().fill(.white).frame(width: 3, height: 3)
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
                .foregroundStyle(readoutColor)
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

    private var readoutColor: Color {
        guard camera.alertEnabled, let d = camera.centerMeters else { return .white }
        return d <= camera.alertThreshold ? .red : .white
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Предупреждение о препятствии") {
                    Toggle("Включено", isOn: $camera.alertEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Порог")
                            Spacer()
                            Text(String(format: "%.0f см", camera.alertThreshold * 100))
                                .font(.body.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Slider(value: $camera.alertThreshold, in: 0.15...2.0, step: 0.05)
                            .tint(.orange)
                    }
                    .disabled(!camera.alertEnabled)

                    Picker("Зона слежения", selection: $camera.alertZone) {
                        ForEach(AlertZone.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!camera.alertEnabled)

                    Text(camera.alertZone.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Вибрация", isOn: $camera.hapticsEnabled)
                        .disabled(!camera.alertEnabled)
                }

                Section {
                    Text("Сглаживание уплотняет карту глубины, используя кадр с камеры. В темноте лучше выключать — там RGB превращается в шум.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Справка")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
