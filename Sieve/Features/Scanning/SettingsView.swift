import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("previewVolume") private var previewVolume = 1.0
    @AppStorage("editorNormalizeDb") private var normalizeDb = -1.0
    @AppStorage("editorMaxMinutes") private var editorMaxMinutes = 10
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

            Divider()

            Picker("Normalize target", selection: $normalizeDb) {
                Text("0 dBFS").tag(0.0)
                Text("−0.3 dBFS").tag(-0.3)
                Text("−1 dBFS").tag(-1.0)
                Text("−3 dBFS").tag(-3.0)
                Text("−6 dBFS").tag(-6.0)
            }
            Stepper(value: $editorMaxMinutes, in: 1...60) {
                Text("Max editable length: \(editorMaxMinutes) min")
            }
            Text("The inspector's Edit tab loads the whole file into memory; longer files stay read-only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
