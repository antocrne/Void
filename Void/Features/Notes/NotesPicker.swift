import Foundation

/// « Envoyer vers Void Notes » when Void Notes lists notes: the panel where one picks a new note
/// or a note to add to, in the tree of Void Notes (NotesPickerOverlay).
struct NotesPickerRequest: Identifiable, Equatable {
    let id = UUID()
    let content: VoidNotes.Content
    weak var tab: Tab?
    let directory: VoidNotes.Directory
    /// The folders open at first (the preview of the self-test); none otherwise.
    var expanded: Set<UUID> = []

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

extension BrowserModel {
    /// `note`: the note to add to; nil, a new note.
    func chooseInNotesPicker(_ note: VoidNotes.NoteTarget?) {
        guard let request = notesPicker else { return }
        notesPicker = nil
        guard let tab = request.tab else { return }
        VoidNotes.shared.deliver(request.content, from: tab, to: note)
    }
}

extension VoidNotes.Directory {
    /// A line of the panel.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case newNote
            case header(String)
            /// `count`: the notes in it and under it.
            case folder(Folder, expanded: Bool, count: Int)
            /// `path`: where it is (space, folders), shown in the results of a search.
            case note(VoidNotes.NoteTarget, path: String)
        }
        let kind: Kind
        var depth = 0

        var id: String {
            switch kind {
            case .newNote: "new"
            case .header(let title): "header:" + title
            case .folder(let folder, _, _): "folder:" + folder.id.uuidString
            case .note(let note, _): "note:" + note.id.uuidString
            }
        }

        var isSelectable: Bool {
            if case .header = kind { false } else { true }
        }
    }

    /// The space a note or a folder is in: its own, or the first one when it doesn't say.
    func space(of id: UUID?) -> UUID? {
        spaces.contains { $0.id == id } ? id : spaces.first?.id
    }

    /// The space shown first: the one of the note changed last.
    var initialSpace: UUID? {
        space(of: (notes.first { !$0.pinned } ?? notes.first)?.space)
    }

    /// The tree of one space, as Void Notes' list shows it: a new note, the pinned notes, the
    /// folders — each one, when `expanded`, followed by its subfolders and its notes —, then the
    /// notes in none. A search instead lists the notes of every space whose title or place has
    /// every word typed, whatever the case and the accents.
    func rows(in space: UUID?, expanded: Set<UUID>, query: String) -> [Row] {
        let words = query.split(whereSeparator: \.isWhitespace).map { Self.folded(String($0)) }
        guard words.isEmpty else { return results(for: words) }

        let known = Set(folders.map(\.id))
        let shown = notes.filter { self.space(of: $0.space) == space }
        let pinned = shown.filter(\.pinned)
        let filed = shown.filter { !$0.pinned && $0.folder.map(known.contains) == true }
        let loose = shown.filter { !$0.pinned && $0.folder.map(known.contains) != true }
        let roots = folders.filter { ($0.parent.map(known.contains) != true) && self.space(of: $0.space) == space }
        let children = Dictionary(grouping: folders.filter { $0.parent.map(known.contains) == true }, by: { $0.parent! })
        var counts: [UUID: Int] = [:]
        for note in filed {
            var folder = note.folder
            var seen = Set<UUID>()
            while let id = folder, seen.insert(id).inserted {
                counts[id, default: 0] += 1
                folder = folders.first { $0.id == id }?.parent
            }
        }

        var rows = [Row(kind: .newNote)]
        let headed = [!pinned.isEmpty, !roots.isEmpty, !loose.isEmpty].filter { $0 }.count > 1
        func header(_ title: LocalizedStringResource) {
            if headed { rows.append(Row(kind: .header(String(localized: title)))) }
        }
        if !pinned.isEmpty {
            header("Épinglées")
            rows += pinned.map { Row(kind: .note($0, path: "")) }
        }
        func add(_ folder: Folder, depth: Int) {
            guard depth < 20 else { return }
            let open = expanded.contains(folder.id)
            rows.append(Row(kind: .folder(folder, expanded: open, count: counts[folder.id] ?? 0), depth: depth))
            guard open else { return }
            for child in children[folder.id] ?? [] { add(child, depth: depth + 1) }
            rows += filed.filter { $0.folder == folder.id }.map { Row(kind: .note($0, path: ""), depth: depth + 1) }
        }
        if !roots.isEmpty {
            header("Dossiers")
            for folder in roots { add(folder, depth: 0) }
        }
        if !loose.isEmpty {
            header("Notes")
            rows += loose.map { Row(kind: .note($0, path: "")) }
        }
        return rows
    }

    /// Space (when there are several), then folders: « Personnel › Travail › Voyages ».
    func path(of note: VoidNotes.NoteTarget) -> String {
        var names: [String] = []
        var folder = note.folder
        var seen = Set<UUID>()
        while let id = folder, seen.insert(id).inserted, let found = folders.first(where: { $0.id == id }) {
            names.insert(found.name, at: 0)
            folder = found.parent
        }
        if spaces.count > 1, let space = spaces.first(where: { $0.id == self.space(of: note.space) }) {
            names.insert(space.name, at: 0)
        }
        return names.joined(separator: " › ")
    }

    private func results(for words: [String]) -> [Row] {
        var rows: [Row] = []
        for note in notes {
            let path = path(of: note)
            let hay = Self.folded(note.title + " " + path)
            if words.allSatisfy(hay.contains) { rows.append(Row(kind: .note(note, path: path))) }
            if rows.count == 50 { break }
        }
        return rows
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
