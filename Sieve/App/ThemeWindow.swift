import SwiftUI

/// The Theme window (Sieve ▸ Theme…), laid out like R3WRK's Theme panel: a "Start from" menu of the
/// built-ins plus every theme saved in the shared folder (so R3WRK's saves show up here), one
/// hex + colour-well row per colour, save-by-name / Delete / Reset, and Copy / Paste for moving
/// a theme to R3WRK (or back) as text. Colours Sieve doesn't paint sit under "R3WRK only" — they
/// ride along in the theme so nothing is lost on the way through.
struct ThemeWindow: View {
    @Environment(\.palette) private var palette
    @AppStorage(ThemeLibrary.activeKey) private var themeText = ""
    @State private var saved: [(name: String, palette: ThemePalette)] = []
    @State private var nameDraft = ""
    @State private var showR3WRKOnly = false
    @State private var pasteFailed = false

    private var theme: ThemePalette { ThemePalette(string: themeText) }
    private func apply(_ t: ThemePalette) { themeText = t.string }

    private var matchingBuiltIn: String? {
        let t = theme
        return ThemePalette.builtIns.first { ThemePalette(string: $0.spec) == t }?.name
    }
    private var matchingSaved: String? {
        let t = theme
        return saved.first { $0.palette == t }?.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Start from").foregroundStyle(.secondary)
                    startFromMenu
                }
                HStack(spacing: 8) {
                    Button("Copy") {
                        ThemeLibrary.copyToClipboard(theme, name: matchingSaved ?? matchingBuiltIn ?? nonEmptyDraft ?? "Untitled")
                    }
                    .help("Copy this theme as text, to Paste into R3WRK's Theme panel")
                    Button("Paste") { paste() }
                        .help("Apply a theme copied from R3WRK (or from another Sieve)")
                    Spacer()
                    Button("Reset") { apply(ThemePalette.builtIn("Ableton Dark Blue-Grey")!) }
                }

                Divider()
                colorGrid(ThemePalette.fields.filter { $0.sieveRole != nil })

                DisclosureGroup("R3WRK only", isExpanded: $showR3WRKOnly) {
                    VStack(alignment: .leading, spacing: 8) {
                        colorGrid(ThemePalette.fields.filter { $0.sieveRole == nil })
                        Toggle("Shaded panel", isOn: Binding(get: { theme.shadedPanel },
                                                             set: { var t = theme; t.shadedPanel = $0; apply(t) }))
                        slider("Edge darken", \.edgeShadeDarken)
                        slider("Edge opacity", \.edgeShadeAlpha)
                    }
                    .padding(.top, 6)
                }

                Divider()
                HStack(spacing: 8) {
                    TextField("", text: $nameDraft, prompt: Text("name to save current as…"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save).disabled(nonEmptyDraft == nil)
                    Button("Delete") {
                        if let name = matchingSaved { ThemeLibrary.delete(name); reloadSaved() }
                    }
                    .disabled(matchingSaved == nil)
                    .help("Delete the selected saved theme (from R3WRK too)")
                }
                Text("Saved themes live in ~/Library/Application Support/Shared Themes, so R3WRK lists them too.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 400)
        .frame(minHeight: 420, idealHeight: 700)
        .background(palette.surface)
        .onAppear(perform: reloadSaved)
        .alert("The clipboard doesn't hold a theme", isPresented: $pasteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use Copy in R3WRK's Theme panel (or here) first.")
        }
    }

    private var startFromMenu: some View {
        Menu(matchingBuiltIn ?? matchingSaved ?? "Custom") {
            Section("Built-in") {
                ForEach(ThemePalette.builtIns, id: \.name) { b in
                    Button(b.name) { apply(ThemePalette(string: b.spec)) }
                }
            }
            if !saved.isEmpty {
                Section("Saved (shared with R3WRK)") {
                    ForEach(saved, id: \.name) { s in
                        Button(s.name) { apply(s.palette) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func colorGrid(_ fields: [ThemePalette.Field]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(fields, id: \.key) { field in
                ThemeColorRow(field: field, value: binding(field.key))
            }
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<ThemePalette, Double>) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { theme[keyPath: key] },
                                  set: { var t = theme; t[keyPath: key] = ($0 * 100).rounded() / 100; apply(t) }),
                   in: 0...1)
            Text(String(format: "%.2f", theme[keyPath: key])).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var nonEmptyDraft: String? {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    private func binding(_ key: String) -> Binding<UInt32> {
        Binding(get: { theme[key] }, set: { var t = theme; t[key] = $0; apply(t) })
    }

    private func save() {
        guard let name = nonEmptyDraft, ThemeLibrary.save(theme, as: name) else { return }
        nameDraft = ""
        reloadSaved()
    }

    private func paste() {
        guard let (palette, name) = ThemeLibrary.pasteFromClipboard() else { pasteFailed = true; return }
        apply(palette)
        // Ready to Save under the name it came with, unless that name's already taken.
        if let name, ThemePalette.builtIn(name) == nil, !saved.contains(where: { $0.name == name }) {
            nameDraft = name
        }
    }

    private func reloadSaved() {
        saved = ThemeLibrary.names().compactMap { n in ThemeLibrary.load(n).map { (n, $0) } }
    }
}

/// One theme colour as a grid row: its label (plus what it paints in Sieve), a colour well, and a
/// hex field that takes `RRGGBB` or `AARRGGBB` (R3WRK's translucent colours, e.g. the grid lines).
private struct ThemeColorRow: View {
    let field: ThemePalette.Field
    @Binding var value: UInt32
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        GridRow {
            VStack(alignment: .leading, spacing: 0) {
                Text(field.label.prefix(1).uppercased() + field.label.dropFirst())
                if let role = field.sieveRole {
                    Text(role).font(.caption).foregroundStyle(.secondary)
                }
            }
            .gridColumnAlignment(.leading)
            Spacer(minLength: 0)
            ColorPicker("", selection: Binding(get: { ThemePalette.color(value) },
                                               set: { value = ThemePalette.argb($0) }),
                        supportsOpacity: true)
                .labelsHidden()
            TextField("", text: $draft, prompt: Text("RRGGBB"))
                .labelsHidden()
                .frame(width: 96)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { draft = ThemePalette.hexString(value) }
        .onChange(of: value) { _, new in if !focused { draft = ThemePalette.hexString(new) } }
    }

    private func commit() {
        if let v = ThemePalette.parseARGB(draft) { value = v }
        draft = ThemePalette.hexString(value)   // canonicalise, or revert if invalid
    }
}
