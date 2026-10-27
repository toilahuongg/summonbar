import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footer
        }
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let crumb = model.breadcrumb {
                Text(crumb)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
            if case .run(let run) = model.screen {
                RunStatusBadge(run: run)
            } else if case .output(let run) = model.screen {
                ExtensionStatusBadge(run: run)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder private var content: some View {
        if case .run(let run) = model.screen {
            RunView(run: run) { model.allowAndRetry(run) }
        } else if case .output(let run) = model.screen {
            ExtensionOutputView(run: run)
        } else if case .translate(let translation) = model.screen {
            TranslateView(translation: translation)
        } else if model.isShowingClipboard {
            HStack(spacing: 0) {
                ResultsList(model: model).frame(width: 330)
                Divider().opacity(0.6)
                ClipboardPreview(entry: model.selectedClipboardEntry, monitoring: model.clipboard.isMonitoring)
            }
        } else {
            ResultsList(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let toast = model.toast {
                Label(toast, systemImage: "info.circle")
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(model.runningCount > 0 ? "\(model.runningCount) agent\(model.runningCount == 1 ? "" : "s") running" : "Summonbar")
            }
            Spacer()
            ForEach(Array(model.hints.enumerated()), id: \.offset) { index, hint in
                if index > 0 { Divider().frame(height: 14) }
                HStack(spacing: 6) {
                    Text(hint.label).foregroundStyle(index == 0 ? .primary : .secondary)
                    KeyCap(hint.keys)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ResultsList: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        if model.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("No results").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || model.items[index - 1].section != item.section {
                                Text(item.section)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 4)
                            }
                            ItemRow(item: item, selected: index == model.selection)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.selection = index; model.performPrimary() }
                                .onTapGesture { model.selection = index }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) {
                    guard model.items.indices.contains(model.selection) else { return }
                    proxy.scrollTo(model.items[model.selection].id)
                }
                .onChange(of: model.query) { proxy.scrollTo("top", anchor: .top) }
            }
        }
    }
}

struct ItemRow: View {
    let item: ListItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(icon: item.icon, tint: item.tint)
            Text(item.title)
                .font(.system(size: 14))
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let accessory = item.accessory {
                Text(accessory).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// An SF Symbol name, an emoji, a path to an image file (extension icons), or a path to an `.app` bundle.
struct ItemIcon: View {
    let icon: String
    let tint: Color

    var body: some View {
        if icon.hasPrefix("/"), icon.hasSuffix(".app") {
            Image(nsImage: AppControl.icon(icon)).resizable().scaledToFit().frame(width: 26, height: 26)
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Group {
            if icon.hasPrefix("/") {
                if let image = NSImage(contentsOfFile: icon) {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                }
            } else if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                Image(systemName: icon)
            } else {
                Text(icon).font(.system(size: 15))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(tint)
        .frame(width: 26, height: 26)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct RunStatusBadge: View {
    @ObservedObject var run: AgentRun

    var body: some View { StatusIcon(status: run.status) }
}

struct ExtensionStatusBadge: View {
    @ObservedObject var run: ExtensionRun

    var body: some View { StatusIcon(status: run.status) }
}

struct StatusIcon: View {
    let status: RunStatus

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct RunView: View {
    @ObservedObject var run: AgentRun
    var onAllow: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.entries) { entry in
                        EntryView(entry: entry)
                    }
                    if !run.deniedRules.isEmpty && run.canFollowUp {
                        Button(action: onAllow) {
                            Label("Allow & Retry", systemImage: "checkmark.shield")
                        }
                        .controlSize(.small)
                        .help("Allow \(run.deniedRules.joined(separator: ", ")) for the rest of this run, then try again")
                    }
                    if !run.live.isEmpty {
                        MarkdownText(run.live)
                    } else if run.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(run.agentName) is working…").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: run.entries.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: run.live) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct ExtensionOutputView: View {
    @ObservedObject var run: ExtensionRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if run.output.isEmpty {
                        HStack(spacing: 8) {
                            if run.isRunning { ProgressView().controlSize(.small) }
                            Text(run.isRunning ? "Running \(run.ext.title)…" : "No output").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    } else {
                        Text(run.output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(run.status == .failed ? Color.red.opacity(0.9) : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: run.output) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct TranslateView: View {
    @ObservedObject var translation: Translation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "character.bubble").foregroundStyle(.indigo)
                    Text(translation.direction)
                    if translation.chosenTarget == nil { Text("· automatic").foregroundStyle(.tertiary) }
                    Spacer()
                    if translation.isTranslating { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                if case .failed(let message) = translation.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.red)
                } else if translation.input.isEmpty {
                    Text("Type or paste text above. ⌘K picks the language; Google Translate does the translating.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(translation.output)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .opacity(translation.isTranslating ? 0.5 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ClipboardPreview: View {
    let entry: ClipboardEntry?
    let monitoring: Bool

    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    content(entry)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details(entry), id: \.0) { label, value in
                        HStack {
                            Text(label).foregroundStyle(.secondary)
                            Spacer()
                            Text(value).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        } else {
            Text(monitoring ? "Copy something and it shows up here." : "Clipboard history is off. Turn it on in Settings › General.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(_ entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .text:
            // Very long text would make SwiftUI lay out megabytes; the copy is still complete.
            let text = entry.text ?? ""
            Text(text.count > 20_000 ? text.prefix(20_000) + "\n…" : text)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
        case .image:
            if let url = entry.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300)
            } else {
                Text("The image file is missing.").foregroundStyle(.secondary)
            }
        case .files:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.fileURLs, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).font(.system(size: 13))
                            Text(url.deletingLastPathComponent().tildePath).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func details(_ entry: ClipboardEntry) -> [(String, String)] {
        var out: [(String, String)] = []
        switch entry.kind {
        case .text:
            let text = entry.text ?? ""
            out.append(("Characters", text.count.formatted()))
            let lines = text.split(whereSeparator: \.isNewline).count
            if lines > 1 { out.append(("Lines", lines.formatted())) }
        case .image:
            if let url = entry.imageURL, let rep = NSImageRep(contentsOf: url) {
                out.append(("Dimensions", "\(rep.pixelsWide) × \(rep.pixelsHigh)"))
            }
        case .files:
            out.append(("Files", entry.fileURLs.count.formatted()))
        }
        if let app = entry.sourceApp { out.append(("Copied from", app)) }
        out.append(("Copied", entry.date.formatted(date: .abbreviated, time: .shortened)))
        return out
    }
}

struct EntryView: View {
    let entry: Entry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.blue)
                Text(entry.text).font(.system(size: 13.5, weight: .semibold)).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            MarkdownText(entry.text)
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: Self.toolIcon(entry.text)).frame(width: 16)
                Text(entry.text).fontWeight(.medium)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .output:
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.isError ? Color.red.opacity(0.85) : Color.secondary.opacity(0.8))
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(.leading, 22)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .info:
            Text(entry.text).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    static func toolIcon(_ name: String) -> String {
        switch name {
        case "Bash", "Shell": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attributed)
            .font(.system(size: 13.5))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
