import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("previewVolume") private var previewVolume = 1.0
    @AppStorage("editorNormalizeDb") private var normalizeDb = -1.0
    @AppStorage("editorMaxMinutes") private var editorMaxMinutes = 10
    @Environment(AppEnvironment.self) private var env
    @State private var recordingsFolder: URL?
    @State private var exportFolder: URL?

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

            Divider()

            LabeledContent("Recordings folder") {
                HStack(spacing: 8) {
                    Text(recordingsFolder?.lastPathComponent ?? "Not set")
                        .foregroundStyle(recordingsFolder == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(recordingsFolder == nil ? "Choose…" : "Change…") { chooseRecordingsFolder() }
                    if recordingsFolder != nil {
                        Button("Clear", role: .destructive) {
                            env.bookmarks.clearRecordingsFolder()
                            recordingsFolder = nil
                        }
                    }
                }
            }
            Text("Where the editor's Record button saves each take.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Export folder") {
                HStack(spacing: 8) {
                    Text(exportFolder?.lastPathComponent ?? "Not set")
                        .foregroundStyle(exportFolder == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(exportFolder == nil ? "Choose…" : "Change…") { chooseExportFolder() }
                    if exportFolder != nil {
                        Button("Clear", role: .destructive) {
                            env.bookmarks.clearExportFolder()
                            exportFolder = nil
                        }
                    }
                }
            }
            Text("Where the editor's Export Selection button writes cropped audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            recordingsFolder = env.bookmarks.lastRecordingsFolder()
            exportFolder = env.bookmarks.lastExportFolder()
        }
    }

    private func chooseRecordingsFolder() {
        guard let url = pickFolder(message: "Choose a folder to save recordings into.") else { return }
        env.bookmarks.rememberRecordingsFolder(url)
        recordingsFolder = url
    }

    private func chooseExportFolder() {
        guard let url = pickFolder(message: "Choose a folder to export selections into.") else { return }
        env.bookmarks.rememberExportFolder(url)
        exportFolder = url
    }

    private func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
