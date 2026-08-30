import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("previewVolume") private var previewVolume = 1.0
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Toggle("Play sample when selected", isOn: $autoPreview)
            Slider(value: $previewVolume, in: 0...1) { Text("Preview volume") }
                .onChange(of: previewVolume, initial: true) { _, v in env.player.volume = Float(v) }
            LabeledContent("Indexed extensions", value: Queries.audioExtensions.joined(separator: ", "))

            Divider()

            LabeledContent("Audio editor") {
                HStack(spacing: 8) {
                    Text(env.audioEditorName ?? "Not set")
                        .foregroundStyle(env.audioEditorName == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer()
                    Button(env.audioEditorName == nil ? "Choose…" : "Change…") { env.chooseAudioEditor() }
                    if env.audioEditorName != nil {
                        Button("Clear", role: .destructive) { env.clearAudioEditor() }
                    }
                }
            }
            Text("The “Open in…” button in the inspector and the sample’s context menu send it to this app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
