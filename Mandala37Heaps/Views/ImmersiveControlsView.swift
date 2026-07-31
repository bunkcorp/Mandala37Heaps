import SwiftUI

struct ImmersiveControlsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appModel.progressLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(appModel.statusMessage, systemImage: "scope")
                    .font(.headline)
                    .foregroundStyle(appModel.playMode == .guided ? .cyan : .primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: 430, alignment: .leading)

            Picker("Mode", selection: $appModel.playMode) {
                ForEach(PlayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: appModel.playMode) { _, newValue in
                appModel.setPlayMode(newValue)
            }

            Button("Reset", systemImage: "arrow.counterclockwise") {
                appModel.resetMandala()
            }
            .buttonStyle(.bordered)

            Button("Exit", systemImage: "xmark.circle.fill") {
                appModel.exitMandala()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
