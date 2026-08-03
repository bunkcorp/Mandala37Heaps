import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            Group {
                if appModel.viewState == .immersive {
#if os(visionOS)
                    // Window-hosted controls while ImmersiveSpace is open
                    // (ornaments are not supported on ImmersiveView).
                    VisionControlsChrome()
#else
                    // iOS: full-screen RealityKit scene + overlay controls.
                    IOSMandalaView()
#endif
                } else {
                    portalContent
                }
            }
            .task {
                appModel.prepareMandalaIfNeeded()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-autoEnter"),
                   !appModel.didProcessDebugLaunchArguments {
                    appModel.didProcessDebugLaunchArguments = true
                    try? await Task.sleep(for: .seconds(1))
                    appModel.enterMandala()
                }
#endif
            }
        }
    }

    private var portalContent: some View {
        @Bindable var appModel = appModel

        return VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("37 Heaps Mandala")
                    .font(.largeTitle.weight(.semibold))
                Text("Build a tiered 37-heap mandala offering — stacked rings like a traditional offering set.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("How to play")
                    .font(.headline)
                Text("• Fill each ring level in order; the next smaller ring appears when a level is complete")
                Text("• Guided mode: tap the glowing beacon to place the next heap")
                Text("• Free mode: pick a material, then tap an empty spot on the unlocked ring")
                Text("• Finish all 37 to place the top ornament")
#if os(iOS)
                Text("• On iPhone: drag to orbit, pinch to zoom, tap heaps to place")
#endif
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Picker("Mode", selection: $appModel.playMode) {
                ForEach(PlayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appModel.playMode) { _, newValue in
                appModel.setPlayMode(newValue)
            }

            Button {
                appModel.enterMandala()
            } label: {
                Text("Begin Offering")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(28)
#if os(visionOS)
        .frame(minWidth: 460, minHeight: 560)
#endif
    }
}

#if os(visionOS)
/// Auto-hides the full control panel while autoplay runs.
private struct VisionControlsChrome: View {
    @Environment(AppModel.self) private var appModel
    @State private var showControls = true

    var body: some View {
        Group {
            if showControls {
                ImmersiveControlsView()
                    .padding(24)
                    .frame(minWidth: 420, idealWidth: 520, minHeight: 220)
            } else {
                HStack(spacing: 12) {
                    Text(appModel.progressLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if appModel.isAutoPlaying {
                        Button("Stop", systemImage: "stop.fill") {
                            appModel.stopAutoPlay()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Menu") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls = true
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .frame(minWidth: 360)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .onChange(of: appModel.isAutoPlaying) { _, playing in
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = !playing
            }
        }
    }
}
#endif
