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
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder private var content: some View {
        if case .run(let run) = model.screen {
            RunView(run: run)
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
            }
        }
    }
}

struct ItemRow: View {
    let item: ListItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.tint)
                .frame(width: 26, height: 26)
                .background(item.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
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

struct RunStatusBadge: View {
    @ObservedObject var run: AgentRun

    var body: some View {
        switch run.status {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct RunView: View {
    @ObservedObject var run: AgentRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.entries) { entry in
                        EntryView(entry: entry)
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
