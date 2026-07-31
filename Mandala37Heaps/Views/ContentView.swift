import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            VStack(spacing: 20) {
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
                    Text("• Guided mode lights the next heap (Meru → continents → treasures → goddesses → sun/moon)")
                    Text("• Finish all 37 to place the top ornament")
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
            .frame(minWidth: 460, minHeight: 560)
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
}
