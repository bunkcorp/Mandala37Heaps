import SwiftUI

struct ImmersiveControlsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appModel.progressLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text(appModel.statusMessage)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "scope")
                }
                .font(.headline)
                .foregroundStyle(appModel.playMode == .guided ? .cyan : .primary)
                .labelStyle(.titleAndIcon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $appModel.playMode) {
                    ForEach(PlayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: appModel.playMode) { _, newValue in
                    appModel.setPlayMode(newValue)
                }

                Picker("Solver", selection: $appModel.solverMode) {
                    ForEach(SolverMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: appModel.solverMode) { _, newValue in
                    appModel.setSolverMode(newValue)
                }

                if appModel.showDiagnosticsHUD {
                    Text(appModel.diagnosticsHUD)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appModel.identificationHUD)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appModel.posteriorHUD)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appModel.surfaceUncertaintyHUD)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appModel.adaptivityHUD)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appModel.neuralResidualHUD)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appModel.solverMode == .mpmActive {
                    HStack(spacing: 10) {
                        Button(appModel.isIdentifying ? "Stop ID" : "Fit ID") {
                            appModel.setIdentifying(!appModel.isIdentifying)
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.solverMode != .mpmActive)

                        Button("Target") {
                            appModel.captureIdentificationTarget()
                        }
                        .buttonStyle(.bordered)

                        Button("Teacher") {
                            appModel.captureSyntheticTeacherTarget()
                        }
                        .buttonStyle(.bordered)

                        Button(appModel.showUncertaintyBands ? "Hide σ" : "Show σ") {
                            appModel.setUncertaintyBandsVisible(!appModel.showUncertaintyBands)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 10) {
                        Button(appModel.isAdaptivityEnabled ? "Adapt Off" : "Adapt On") {
                            appModel.setAdaptivityEnabled(!appModel.isAdaptivityEnabled)
                        }
                        .buttonStyle(.bordered)

                        Button(appModel.showAdaptivityHeatmap ? "Hide e" : "Show e") {
                            appModel.setAdaptivityHeatmapVisible(!appModel.showAdaptivityHeatmap)
                        }
                        .buttonStyle(.bordered)

                        Button(appModel.isNeuralResidualEnabled ? "Neural Off" : "Neural On") {
                            appModel.setNeuralResidualEnabled(!appModel.isNeuralResidualEnabled)
                        }
                        .buttonStyle(.bordered)

                        Button(appModel.showNeuralResidualSurface ? "Hide δh" : "Show δh") {
                            appModel.setNeuralResidualSurfaceVisible(!appModel.showNeuralResidualSurface)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack(spacing: 12) {
                    Button(
                        appModel.isAutoPlaying ? "Stop" : "Play",
                        systemImage: appModel.isAutoPlaying ? "stop.fill" : "play.fill"
                    ) {
                        appModel.toggleAutoPlay()
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isComplete && !appModel.isAutoPlaying)
                    .accessibilityLabel(appModel.isAutoPlaying ? "Stop autoplay" : "Play remaining heaps")

                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        appModel.resetMandala()
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    Button("Exit", systemImage: "xmark.circle.fill") {
                        appModel.exitMandala()
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
