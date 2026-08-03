import RealityKit
import SwiftUI

#if os(iOS)
/// iPhone / iPad tabletop RealityKit experience (same mandala gameplay as visionOS).
struct IOSMandalaView: View {
    @Environment(AppModel.self) private var appModel
    @State private var orbitYaw: Float = 0.25
    /// Positive pitch tips the top toward the camera (look over the heaps).
    @State private var orbitPitch: Float = 0.55
    @State private var orbitScale: Float = 0.92
    @State private var pinchStartScale: Float = 0.92
    @State private var isPinching = false
    @State private var toolDragStart: SIMD3<Float>?
    @State private var isOrbiting = false
    @State private var lastOrbitTranslation: CGSize = .zero
    @State private var showControls = true

    /// Near side-on (slight top) … steep top-down. Small negative keeps a peek at the underside.
    private let pitchRange: ClosedRange<Float> = -0.25...1.35
    private let scaleRange: ClosedRange<Float> = 0.45...4.0

    var body: some View {
        ZStack {
            RealityView { content in
                appModel.prepareMandalaIfNeeded()
                appModel.applyPlatformPresentation()
                if appModel.mandalaRoot.parent == nil {
                    content.add(appModel.mandalaRoot)
                }
                applyOrbit()
            } update: { _ in
                applyOrbit()
            }
            .gesture(
                SpatialTapGesture()
                    .targetedToAnyEntity()
                    .onEnded { value in
                        if appModel.isRitualTool(value.entity) { return }
                        appModel.handleTap(on: value.entity)
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .targetedToAnyEntity()
                    .onChanged { value in
                        if appModel.isRitualTool(value.entity) {
                            if toolDragStart == nil {
                                toolDragStart = appModel.ritualTool.toolEntity.position
                            }
                            let start = toolDragStart ?? .zero
                            let dx = Float(value.translation.width) * 0.0012
                            let dy = Float(-value.translation.height) * 0.0010
                            appModel.ritualTool.updateDraggedPosition(start + SIMD3(dx, dy, 0))
                            return
                        }
                        isOrbiting = true
                        applyOrbitDrag(value.translation)
                    }
                    .onEnded { _ in
                        toolDragStart = nil
                        isOrbiting = false
                        lastOrbitTranslation = .zero
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard !isOrbiting else { return }
                        applyOrbitDrag(value.translation)
                    }
                    .onEnded { _ in
                        lastOrbitTranslation = .zero
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            pinchStartScale = orbitScale
                        }
                        let next = pinchStartScale * Float(value.magnification)
                        orbitScale = min(scaleRange.upperBound, max(scaleRange.lowerBound, next))
                    }
                    .onEnded { _ in
                        isPinching = false
                        pinchStartScale = orbitScale
                    }
            )
            .ignoresSafeArea()

            VStack {
                if showControls {
                    ImmersiveControlsView()
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    HStack(spacing: 10) {
                        Text(appModel.progressLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if appModel.isAutoPlaying {
                            Button("Stop", systemImage: "stop.fill") {
                                appModel.stopAutoPlay()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .font(.caption2.weight(.semibold))
                        }
                        Button("Menu", systemImage: "slider.horizontal.3") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls = true
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: showControls)
        }
        .onChange(of: appModel.isAutoPlaying) { _, playing in
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = !playing
            }
        }
#if DEBUG
        .task {
            guard !appModel.didRunDebugGameplay else { return }
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-autoPlay") || arguments.contains("-autoDemo") else { return }
            appModel.didRunDebugGameplay = true
            try? await Task.sleep(for: .seconds(1.2))
            if arguments.contains("-autoPlay") {
                appModel.startAutoPlay()
            } else {
                await appModel.debugPlaceDemoHeaps()
            }
        }
#endif
    }

    private func applyOrbitDrag(_ translation: CGSize) {
        let dx = Float(translation.width - lastOrbitTranslation.width)
        let dy = Float(translation.height - lastOrbitTranslation.height)
        lastOrbitTranslation = translation
        orbitYaw += dx * 0.008
        // Drag down → tip top toward camera (look over the mandala).
        orbitPitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, orbitPitch + dy * 0.006))
    }

    private func applyOrbit() {
        let pitch = simd_quatf(angle: orbitPitch, axis: SIMD3(1, 0, 0))
        let yaw = simd_quatf(angle: orbitYaw, axis: SIMD3(0, 1, 0))
        appModel.mandalaRoot.orientation = pitch * yaw
        appModel.mandalaRoot.scale = SIMD3(repeating: orbitScale)
    }
}
#endif
