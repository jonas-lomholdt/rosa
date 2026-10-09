import AppKit

/// Borderless address field with history autocomplete: inline completion of the best
/// match plus a suggestions dropdown navigable with ↑/↓.
final class AddressField: NSTextField, NSTextFieldDelegate {
    var onFocus: (() -> Void)?
    /// Called with the text or URL to load when the user presses ↩ or picks a suggestion, plus
    /// what they had typed when it came from history (so the address bar can learn the pick).
    var onSubmit: ((_ text: String, _ pickedFor: String?) -> Void)?
    /// Called on Escape when no suggestions are open.
    var onCancel: (() -> Void)?
    /// Called when the field stops being edited (after submit or cancel, or a click elsewhere).
    var onEndEditing: (() -> Void)?

    private let suggestions = SuggestionsWindow()
    private var entries: [HistoryEntry] = []
    /// What the user actually typed, excluding any inline completion.
    private var typedText = ""
    private var inlineCompletion: HistoryStore.InlineCompletion?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholderString = "Search or enter address"
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.sendsActionOnEndEditing = false
        delegate = self
        suggestions.onPick = { [weak self] index in
            self?.suggestions.selectedIndex = index
            self?.submit()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            typedText = stringValue
            HistoryStore.shared.prepareSearch()
            onFocus?()
        }
        return accepted
    }

    /// A click that focuses the field selects the whole address (like ⌘L), so typing replaces it;
    /// a drag still selects what it covers. Once editing, the field editor covers the field and
    /// takes the clicks, so this only sees the focusing one.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if let editor, editor.selectedRange.length == 0 {
            editor.selectAll(nil)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        updateSuggestions()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hideSuggestions()
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if suggestions.isVisible {
                // First Escape drops the suggestions and any completion; the second leaves the field.
                hideSuggestions()
                setEditorText(typedText)
            } else {
                onCancel?()
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            return moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            return moveSelection(by: -1)
        default:
            return false
        }
    }

    // MARK: - Autocomplete

    private var editor: NSTextView? { currentEditor() as? NSTextView }

    private func updateSuggestions() {
        guard let editor else { return }
        let text = editor.string
        // Don't re-complete while the user is deleting, or backspace could never remove a completion.
        let isDeleting = text.count <= typedText.count
        typedText = text
        inlineCompletion = nil

        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hideSuggestions() }

        entries = HistoryStore.shared.search(query)
        suggestions.show(entries, below: anchorView)

        let match = HistoryStore.shared.defaultMatch(for: text, in: entries, completes: !isDeleting)
        if let completion = match.completion {
            let typedLength = (text as NSString).length
            editor.string = completion.text
            editor.setSelectedRange(NSRange(location: typedLength, length: (completion.text as NSString).length - typedLength))
            inlineCompletion = completion
        }
        if match.selectsTop { suggestions.selectedIndex = 0 }
    }

    private func moveSelection(by delta: Int) -> Bool {
        guard suggestions.isVisible, !entries.isEmpty else { return false }
        let index = min(max(suggestions.selectedIndex + delta, -1), entries.count - 1)
        suggestions.selectedIndex = index
        inlineCompletion = nil
        setEditorText(index >= 0 ? entries[index].url.absoluteString : typedText)
        return true
    }

    private func submit() {
        let text: String
        var pickedFor: String?
        if suggestions.selectedIndex >= 0, entries.indices.contains(suggestions.selectedIndex) {
            text = entries[suggestions.selectedIndex].url.absoluteString
            pickedFor = typedText
        } else if let inlineCompletion, editor?.string == inlineCompletion.text {
            text = inlineCompletion.url.absoluteString
            pickedFor = typedText
        } else {
            text = editor?.string ?? stringValue
        }
        hideSuggestions()
        onSubmit?(text, pickedFor)
    }

    private func hideSuggestions() {
        suggestions.hide()
        entries = []
        inlineCompletion = nil
    }

    private func setEditorText(_ text: String) {
        guard let editor else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// The glass capsule around the field, so the dropdown lines up with it.
    private var anchorView: NSView {
        var view = superview
        while let current = view {
            if current is GlassAddressBar { return current }
            view = current.superview
        }
        return self
    }

    // MARK: - Testing

    /// Current suggestion titles/URLs, for the self-test.
    var debugSuggestions: [String] { suggestions.isVisible ? entries.map(\.displayURL) : [] }
}
