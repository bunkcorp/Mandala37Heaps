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
