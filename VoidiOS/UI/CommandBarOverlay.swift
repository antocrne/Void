import SwiftUI

/// The address bar, over the page: one field for URLs and searches, with the same suggestions as
/// on the Mac (history, bookmarks, open tabs, downloads, conversions).
struct CommandBarOverlay: View {
    let request: CommandBarRequest
    @Environment(BrowserModel.self) private var browser
    @State private var text = ""
    /// Recomputed when the text changes only: it queries the history database.
    @State private var suggestions: [Suggestion] = []
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 50

    var body: some View {
        ZStack(alignment: .top) {
            // The page behind is blurred and darkened: the bar and its suggestions stand apart from it.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.45)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                field
                if !suggestions.isEmpty {
                    Divider().opacity(0.5)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(suggestions) { suggestion in
                                SuggestionRow(suggestion: suggestion) { text = $0 }
                                    .frame(height: Self.rowHeight)
                                    .contentShape(Rectangle())
                                    .onTapGesture { run(suggestion) }
                            }
                        }
                        .padding(6)
                    }
                    // As tall as its rows, or what is left above the keyboard.
                    .frame(maxHeight: CGFloat(suggestions.count) * (Self.rowHeight + 2) + 12)
                }
            }
            .frame(maxWidth: 640)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 30, y: 12)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            text = request.text
            suggestions = SuggestionEngine.suggestions(for: text, browser: browser)
        }
        .task {
            // Once the overlay is in place (and a sheet that led here is gone).
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
            guard !request.text.isEmpty else { return }
            // The current address is selected: typing replaces it.
            try? await Task.sleep(for: .milliseconds(120))
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: browser.isPrivate ? "eye.slash" : (request.mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass"))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
            TextField(placeholder, text: $text)
                .font(.system(size: 17))
                .foregroundStyle(Theme.primaryText)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onChange(of: text) { _, typed in
                    suggestions = SuggestionEngine.suggestions(for: typed, browser: browser)
                }
                // Exchange rates that have just arrived: the conversion typed gets its answer.
                .onChange(of: CurrencyRates.shared.revision) {
                    suggestions = SuggestionEngine.suggestions(for: text, browser: browser)
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer")
            }
            Button("Annuler") { dismiss() }
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var placeholder: String {
        switch request.mode {
        case .currentTab: Tab.addressPlaceholder
        case .newTab: browser.isPrivate ? "Nouvel onglet privé" : "Nouvel onglet"
        }
    }

    /// ↩: the first suggestion — the address typed when it is one, the search otherwise.
    private func commit() {
        // From the text as it is now: the list on screen can be one keystroke behind.
        if let first = SuggestionEngine.suggestions(for: text, browser: browser).first {
            run(first)
        } else if !text.isEmpty {
            browser.navigate(text, mode: request.mode)
            dismiss()
        } else {
            dismiss()
        }
    }

    private func run(_ suggestion: Suggestion) {
        dismiss()
        suggestion.perform(in: browser, mode: request.mode)
    }

    private func dismiss() {
        focused = false
        browser.commandBar = nil
    }
}

/// A suggestion of the address bar or of the new-tab page.
struct SuggestionRow: View {
    let suggestion: Suggestion
    /// Puts the suggestion in the field, to carry on typing from it.
    let refine: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(suggestion.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let refined {
                Button { refine(refined) } label: {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reprendre dans la barre d'adresse")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
    }

    private var refined: String? {
        switch suggestion.kind {
        case .go(let url): url.absoluteString
        default: nil
        }
    }
}
