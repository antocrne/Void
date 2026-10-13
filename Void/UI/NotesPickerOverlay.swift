#if os(macOS)
import SwiftUI

/// « Envoyer vers Void Notes » when Void Notes lists notes: a floating panel, like the command
/// bar, with the tree of Void Notes — its spaces, folders and subfolders, notes. ↩ on « Nouvelle
/// note » (selected first) sends as before; on a note, adds at its end. → and ← open and close a
/// folder, typing searches every space, Esc or a click outside cancels.
struct NotesPickerOverlay: View {
    let request: NotesPickerRequest
    /// Width of the docked sidebar: the panel is centered on the page, not on the whole window.
    var leadingInset: CGFloat = 0
    @Environment(BrowserModel.self) private var browser
    @State private var query = ""
    @State private var space: UUID?
    @State private var expanded: Set<UUID> = []
    @State private var selectedID = "new"
    @FocusState private var focused: Bool

    private var directory: VoidNotes.Directory { request.directory }
    private var rows: [VoidNotes.Directory.Row] { directory.rows(in: space, expanded: expanded, query: query) }

    var body: some View {
        GeometryReader { geo in
            content(width: min(480, max(320, geo.size.width - leadingInset - 32)), height: geo.size.height)
        }
        .onAppear {
            space = directory.initialSpace
            expanded = request.expanded
            DispatchQueue.main.async { focused = true }
        }
    }

    private func content(width: CGFloat, height: CGFloat) -> some View {
        let rows = rows
        return ZStack(alignment: .top) {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                header
                field(rows)
                if query.isEmpty && directory.spaces.count > 1 {
                    spaceBar
                }
                Divider().opacity(0.5)
                list(rows)
                    .frame(maxHeight: max(160, min(400, height - 330)))
                Divider().opacity(0.5)
                footer
            }
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 90)
            .padding(.leading, leadingInset)
        }
        // A search, a space, a folder closed: the selection stays on a row that is there.
        .onChange(of: rows.map(\.id)) {
            if !rows.contains(where: { $0.id == selectedID && $0.isSelectable }) {
                selectedID = rows.first(where: \.isSelectable)?.id ?? "new"
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func field(_ rows: [VoidNotes.Directory.Row]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
            TextField(String(localized: "Rechercher une note"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { commit(rows) }
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.rightArrow) { fold(true, in: rows) ? .handled : .ignored }
                .onKeyPress(.leftArrow) { fold(false, in: rows) ? .handled : .ignored }
                .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// The spaces of Void Notes, as its space bar shows them.
    private var spaceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(directory.spaces) { item in
                    let selected = item.id == space
                    Button {
                        space = item.id
                        selectedID = "new"
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 10.5, weight: .medium))
                            Text(item.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                        }
                        .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(selected ? Theme.accentSoft : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private func list(_ rows: [VoidNotes.Directory.Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(rows) { row in
                        NotesPickerRow(row: row, selected: row.id == selectedID)
                            .id(row.id)
                            .onTapGesture { if row.isSelectable { selectedID = row.id; run(row) } }
                            .onHover { if $0 && row.isSelectable { selectedID = row.id } }
                    }
                    if rows.isEmpty {
                        Text("Aucune note ne correspond")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
                .padding(6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedID) { proxy.scrollTo(selectedID) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("return", "Ajouter")
            hint("arrow.right", "Ouvrir un dossier")
            hint("escape", "Annuler")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func hint(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(Theme.secondaryText)
    }

    private var title: String {
        switch request.content {
        case .selection: String(localized: "Envoyer vers Void Notes")
        case .page: String(localized: "Envoyer la page vers Void Notes")
        case .image: String(localized: "Envoyer l'image vers Void Notes")
        }
    }

    /// What goes: the start of the selection, or the page it comes from.
    private var subtitle: String {
        let page = request.tab?.displayTitle ?? ""
        switch request.content {
        case .selection(let text):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return "« " + (line.count > 70 ? line.prefix(70) + "…" : line) + " »"
        case .page, .image: return page
        }
    }

    // MARK: Keys

    private func move(_ delta: Int, in rows: [VoidNotes.Directory.Row]) {
        let selectable = rows.filter(\.isSelectable)
        guard !selectable.isEmpty else { return }
        let index = selectable.firstIndex { $0.id == selectedID } ?? 0
        selectedID = selectable[(index + delta + selectable.count) % selectable.count].id
    }

    /// → opens the folder selected, ← closes it, or the one the selected row is in. While a
    /// search is typed, the arrows move in the field.
    private func fold(_ open: Bool, in rows: [VoidNotes.Directory.Row]) -> Bool {
        guard query.isEmpty, let index = rows.firstIndex(where: { $0.id == selectedID }) else { return false }
        if case .folder(let folder, let isOpen, _) = rows[index].kind, open != isOpen {
            if open { expanded.insert(folder.id) } else { expanded.remove(folder.id) }
            return true
        }
        guard !open, rows[index].depth > 0 else { return true }
        // The folder above, one level up.
        if let parent = rows[..<index].last(where: { $0.depth == rows[index].depth - 1 }),
           case .folder(let folder, _, _) = parent.kind {
            expanded.remove(folder.id)
            selectedID = parent.id
        }
        return true
    }

    private func commit(_ rows: [VoidNotes.Directory.Row]) {
        if let row = rows.first(where: { $0.id == selectedID && $0.isSelectable }) { run(row) }
    }

    private func run(_ row: VoidNotes.Directory.Row) {
        switch row.kind {
        case .newNote: choose(nil)
        case .note(let note, _): choose(note)
        case .folder(let folder, let open, _):
            if open { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        case .header: break
        }
    }

    private func choose(_ note: VoidNotes.NoteTarget?) {
        restoreFocus()
        browser.chooseInNotesPicker(note)
    }

    private func dismiss() {
        browser.notesPicker = nil
        restoreFocus()
    }

    private func restoreFocus() {
        if let webView = browser.selectedTab?.webView { webView.window?.makeFirstResponder(webView) }
    }
}

private struct NotesPickerRow: View {
    let row: VoidNotes.Directory.Row
    let selected: Bool

    var body: some View {
        switch row.kind {
        case .header(let title):
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(height: 26, alignment: .bottom)
        default:
            line
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            switch row.kind {
            case .newNote:
                symbol("plus", color: Theme.accent)
                label(String(localized: "Nouvelle note"), weight: .medium)
            case .folder(let folder, let open, _):
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                symbol(folder.icon, color: Theme.secondaryText)
                label(folder.name, weight: .medium)
            case .note(let note, let path):
                if row.depth > 0 { Color.clear.frame(width: 10, height: 1) }
                symbol(note.pinned ? "pin" : "doc.text", color: selected ? Theme.accent : Theme.secondaryText)
                label(note.title, weight: .regular)
                if !path.isEmpty {
                    Text(path)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .header:
                EmptyView()
            }
            Spacer(minLength: 4)
            if case .folder(_, _, let count) = row.kind {
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            if selected {
                Image(systemName: isFolder ? "arrow.right" : "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
    }

    private var isFolder: Bool {
        if case .folder = row.kind { true } else { false }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 16)
    }

    private func label(_ text: String, weight: Font.Weight) -> some View {
        Text(text)
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
    }
}
#endif
