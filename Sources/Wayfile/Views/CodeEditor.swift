import AppKit
import SwiftUI

/// Script editor: an NSTextView with syntax highlighting, line numbers, auto-indent,
/// `wayfile.` completion (JavaScript) and a highlighted error line.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: Script.Language
    /// 1-based line to mark as the error, if any.
    var errorLine: Int?
    /// Read-only previews (versions, imports) still get highlighting and line numbers.
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.language = language
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Coordinator.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.typingAttributes = [.font: Coordinator.font, .foregroundColor: NSColor.textColor]
        textView.setAccessibilityLabel("Script source")
        textView.string = text
        textView.isEditable = editable
        textView.delegate = context.coordinator
        scroll.documentView = textView

        let ruler = LineNumberRuler(textView: textView, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.highlight()
        context.coordinator.markError(errorLine)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.language != language {
            textView.language = language
            coordinator.highlight()
        }
        // Loaded or reverted from outside.
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= (text as NSString).length }
            coordinator.highlight()
        }
        if coordinator.errorLine != errorLine { coordinator.markError(errorLine) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var parent: CodeEditor
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRuler?
        var errorLine: Int?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            ruler?.needsDisplay = true
        }

        @objc func scrolled() { ruler?.needsDisplay = true }

        static func color(_ kind: SyntaxHighlighter.Kind) -> NSColor {
            switch kind {
            case .comment: return .secondaryLabelColor
            case .string: return .systemRed
            case .number: return .systemPurple
            case .keyword: return .systemPink
            case .api: return .systemTeal
            case .annotation: return .systemOrange
            }
        }

        /// Recolours the whole text; scripts are small, so this stays fast.
        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: full)
            for token in SyntaxHighlighter.tokens(storage.string, language: textView.language) where NSMaxRange(token.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: Self.color(token.kind), range: token.range)
            }
            storage.endEditing()
        }

        func markError(_ line: Int?) {
            errorLine = line
            ruler?.errorLine = line
            ruler?.needsDisplay = true
            guard let textView, let layout = textView.layoutManager else { return }
            let s = textView.string as NSString
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
            guard let line, let range = Self.range(ofLine: line, in: s) else { return }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18), forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }

        /// Character range of a 1-based line.
        static func range(ofLine line: Int, in s: NSString) -> NSRange? {
            guard line > 0 else { return nil }
            var current = 1
            var index = 0
            while current < line {
                let r = s.lineRange(for: NSRange(location: index, length: 0))
                guard NSMaxRange(r) < s.length || (NSMaxRange(r) == s.length && s.length > 0 && s.character(at: s.length - 1) == 10) else { return nil }
                index = NSMaxRange(r)
                current += 1
            }
            guard index <= s.length else { return nil }
            return s.lineRange(for: NSRange(location: index, length: 0))
        }
    }
}

/// The text view: auto-indent, tab as spaces, dedent on closing brackets, API completion.
final class CodeTextView: NSTextView {
    var language: Script.Language = .javascript

    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let cursor = selectedRange().location
        let lineStart = s.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = s.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        let indent = CodeIndent.indent(after: before, language: language)
        super.insertNewline(sender)
        if !indent.isEmpty { super.insertText(indent, replacementRange: selectedRange()) }
    }

    override func insertTab(_ sender: Any?) {
        super.insertText(CodeIndent.unit(language), replacementRange: selectedRange())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if CodeIndent.dedentTriggers(language).contains(typed), replacementRange.location == NSNotFound || replacementRange.length == 0 {
            dedentCurrentLineIfBlank()
        }
        super.insertText(string, replacementRange: replacementRange)
        if language == .javascript, typed == ".", chainBeforeCursor().hasPrefix("wayfile.") {
            DispatchQueue.main.async { [weak self] in self?.complete(nil) }
        }
    }

    /// "}" typed on a line holding only indentation moves the line out one level.
    private func dedentCurrentLineIfBlank() {
        let s = string as NSString
        let cursor = selectedRange().location
        let lineStart = s.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = s.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        let unit = CodeIndent.unit(language)
        guard !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }), before.hasSuffix(unit) else { return }
        let range = NSRange(location: cursor - (unit as NSString).length, length: (unit as NSString).length)
        if shouldChangeText(in: range, replacementString: "") {
            replaceCharacters(in: range, with: "")
            didChangeText()
        }
    }

    /// The identifier chain ending at the cursor, e.g. "wayfile.dialogs.co".
    private func chainBeforeCursor() -> String {
        let s = string as NSString
        var start = selectedRange().location
        while start > 0 {
            let c = s.character(at: start - 1)
            let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36 || c == 46
            if !ok { break }
            start -= 1
        }
        return s.substring(with: NSRange(location: start, length: selectedRange().location - start))
    }

    override var rangeForUserCompletion: NSRange {
        guard language == .javascript else { return super.rangeForUserCompletion }
        let chain = chainBeforeCursor()
        let partial = chain.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let length = (partial as NSString).length
        return NSRange(location: selectedRange().location - length, length: length)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard language == .javascript else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        let chain = chainBeforeCursor()
        let list = ScriptAPI.completions(for: chain.contains(".") ? chain : "wayfile." + chain).map(\.insertion)
        index.pointee = list.isEmpty ? -1 : 0
        return list
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        // Picking a namespace ("dialogs.") goes straight on to its members.
        if flag && word.hasSuffix(".") && movement != NSTextMovement.cancel.rawValue {
            DispatchQueue.main.async { [weak self] in self?.complete(nil) }
        }
    }
}

/// Line numbers beside the text, with the error line in red.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    var errorLine: Int?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let s = textView.string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        func draw(_ number: Int, y: CGFloat, height: CGFloat) {
            let isError = number == errorLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isError ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold) : font,
                .foregroundColor: isError ? NSColor.systemRed : NSColor.tertiaryLabelColor,
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (height - size.height) / 2), withAttributes: attributes)
        }

        // Start at the beginning of the first visible line (it may be wrapped above the fold).
        var index = s.length == 0 ? 0 : s.lineRange(for: NSRange(location: min(chars.location, s.length - 1), length: 0)).location
        var line = 1
        for i in 0..<index where s.character(at: i) == 10 { line += 1 }
        while index < NSMaxRange(chars) {
            let lineRange = s.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(line, y: fragment.minY + offset, height: fragment.height)
            line += 1
            index = NSMaxRange(lineRange)
        }
        // The empty line after a trailing newline (or an empty document).
        if s.length == 0 || (index >= s.length && s.character(at: s.length - 1) == 10) {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { draw(line, y: extra.minY + offset, height: extra.height) }
        }
    }
}
