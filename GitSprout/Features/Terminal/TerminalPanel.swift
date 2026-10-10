import AppKit
import CoreText
import SwiftTerm
import SwiftUI

/// シェル自体は SwiftTerm が疑似端末の別スレッドで動かす。
struct TerminalPanel: NSViewRepresentable {
    var directory: String
    var focusToken: Int
    var fontSize: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalChromeView {
        let terminal = MatchingTerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        terminal.hideScroller()
        let view = TerminalChromeView(terminal: terminal)
        terminal.processDelegate = context.coordinator
        terminal.applyInterfaceColors()
        applyFont(terminal)
        return view
    }

    func updateNSView(_ nsView: TerminalChromeView, context: Context) {
        let terminal = nsView.terminal
        applyFont(terminal)
        if context.coordinator.appliedFocusToken != focusToken {
            let shouldFocus = focusToken > 0
            context.coordinator.appliedFocusToken = focusToken
            if shouldFocus {
                terminal.focusWhenReady = true
                terminal.focusIfNeeded()
            }
        }
        guard !context.coordinator.didStart else { return }
        context.coordinator.didStart = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(executable: shell, args: ["-l"], currentDirectory: directory)
    }

    private func applyFont(_ terminal: MatchingTerminalView) {
        let size = CGFloat(min(24, max(10, fontSize)))
        guard abs(terminal.font.pointSize - size) > 0.1 else { return }
        terminal.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func dismantleNSView(_ nsView: TerminalChromeView, coordinator: Coordinator) {
        nsView.terminal.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var didStart = false
        var appliedFocusToken = 0

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// 端末の周囲に余白を取り、余白も端末と同じ背景色で塗る。
final class TerminalChromeView: NSView {
    let terminal: MatchingTerminalView
    static let padding: CGFloat = 8

    init(terminal: MatchingTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    func syncBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }
}

/// 変換確定前の文字列。SwiftTerm は `setMarkedText` を描かないので、カーソル位置に重ねて見せる。
final class IMECompositionView: NSView {
    private let label: NSTextField

    var text = NSAttributedString() {
        didSet { label.attributedStringValue = text }
    }
    var fillColor: NSColor = .textBackgroundColor {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        let field = NSTextField(labelWithAttributedString: NSAttributedString())
        let cell = FlatTextFieldCell(textCell: "")
        cell.isBezeled = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.drawsBackground = false
        cell.lineBreakMode = .byClipping
        cell.wraps = false
        cell.isScrollable = true
        field.cell = cell
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        label = field
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func width(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(text)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 4
    }

    /// テキストフィールド標準の余白を消して、測った幅いっぱいまで文字を出す。
    private final class FlatTextFieldCell: NSTextFieldCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
        override func titleRect(forBounds rect: NSRect) -> NSRect { rect }
    }
}

/// 変更一覧と同じリスト背景と文字色に合わせる。ライト／ダークの切り替わりも追う。
final class MatchingTerminalView: LocalProcessTerminalView {
    var focusWhenReady = false
    private var appliedAppearance: NSAppearance.Name?
    private var markedSource: NSAttributedString?
    private var displayedMarkedText: NSAttributedString?
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var compositionView: IMECompositionView?

    override func layout() {
        super.layout()
        hideScroller()
        updateCompositionFrame()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        updateCompositionFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideScroller()
        applyInterfaceColors()
        focusIfNeeded()
    }

    func hideScroller() {
        for case let scroller as NSScroller in subviews {
            scroller.isHidden = true
            scroller.removeFromSuperview()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInterfaceColors()
    }

    func focusIfNeeded() {
        guard focusWhenReady, let window else { return }
        focusWhenReady = false
        window.makeFirstResponder(self)
    }

    func applyInterfaceColors() {
        let appearance = effectiveAppearance
        guard let kind = appearance.bestMatch(from: [.darkAqua, .aqua]) else { return }
        if window != nil, kind == appliedAppearance { return }
        if window != nil {
            appliedAppearance = kind
        }
        let background = Self.resolve(NSColor.controlBackgroundColor, appearance: appearance)
        let foreground = Self.resolve(NSColor.labelColor, appearance: appearance)
        nativeBackgroundColor = background
        nativeForegroundColor = foreground
        caretColor = foreground
        layer?.backgroundColor = background.cgColor
        (superview as? TerminalChromeView)?.syncBackground(background)
        refreshCompositionColors()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        clearMarkedText()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let source = Self.markedString(from: string)
        guard source.length > 0 else {
            clearMarkedText()
            return
        }
        markedSource = source
        markedSelection = selectedRange
        let styled = styledMarkedText(source)
        displayedMarkedText = styled
        let view = ensureCompositionView()
        view.text = styled
        view.isHidden = false
        refreshCompositionColors()
        updateCompositionFrame()
    }

    override func unmarkText() {
        clearMarkedText()
    }

    override func hasMarkedText() -> Bool {
        (markedSource?.length ?? 0) > 0
    }

    override func markedRange() -> NSRange {
        guard let markedSource, markedSource.length > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedSource.length)
    }

    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let markedSource, range.location != NSNotFound else { return nil }
        let intersection = NSIntersectionRange(range, NSRange(location: 0, length: markedSource.length))
        guard intersection.length > 0 else { return nil }
        actualRange?.pointee = intersection
        return markedSource.attributedSubstring(from: intersection)
    }

    override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .foregroundColor, .backgroundColor, .markedClauseSegment]
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let displayedMarkedText, let compositionView, !compositionView.isHidden, compositionView.frame.width > 0 else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        let full = NSRange(location: 0, length: displayedMarkedText.length)
        let clampedLocation = min(max(range.location, 0), full.length)
        let line = CTLineCreateWithAttributedString(displayedMarkedText)
        let xOffset = CTLineGetOffsetForStringIndex(line, clampedLocation, nil)
        var rect = compositionView.frame
        rect.origin.x += xOffset
        let selection = NSIntersectionRange(range, full)
        actualRange?.pointee = selection.length > 0 ? selection : NSRange(location: clampedLocation, length: 0)
        if selection.length > 0 {
            let end = CTLineGetOffsetForStringIndex(line, selection.location + selection.length, nil)
            rect.size.width = max(end - xOffset, 1)
        }
        guard let window else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func ensureCompositionView() -> IMECompositionView {
        if let compositionView { return compositionView }
        let view = IMECompositionView(frame: .zero)
        view.isHidden = true
        addSubview(view)
        view.layer?.zPosition = 1_000
        compositionView = view
        return view
    }

    private func refreshCompositionColors() {
        guard let compositionView, let markedSource else { return }
        compositionView.fillColor = nativeBackgroundColor
        let styled = styledMarkedText(markedSource)
        displayedMarkedText = styled
        compositionView.text = styled
    }

    private func clearMarkedText() {
        guard markedSource != nil || compositionView?.isHidden == false else { return }
        markedSource = nil
        displayedMarkedText = nil
        markedSelection = NSRange(location: NSNotFound, length: 0)
        compositionView?.text = NSAttributedString()
        compositionView?.isHidden = true
        inputContext?.invalidateCharacterCoordinates()
    }

    private func updateCompositionFrame() {
        guard let compositionView, displayedMarkedText != nil, !compositionView.isHidden else { return }
        let next = NSIntegralRect(compositionFrame())
        guard compositionView.frame != next else { return }
        compositionView.frame = next
        compositionView.layoutSubtreeIfNeeded()
        inputContext?.invalidateCharacterCoordinates()
    }

    private func compositionFrame() -> NSRect {
        let caret = caretRect()
        let textWidth = IMECompositionView.width(of: displayedMarkedText ?? NSAttributedString())
        let width = max(textWidth, caret.width)
        var x = caret.minX
        if bounds.width > 1, x + width > bounds.width {
            x = max(0, bounds.width - width)
        }
        return NSRect(x: x, y: caret.minY, width: width, height: max(caret.height, 1))
    }

    private func caretRect() -> NSRect {
        let frame = caretFrame
        if frame.width >= 1, frame.height >= 1 {
            return frame
        }
        let (column, row) = terminal.getCursorLocation()
        let sample = ("W" as NSString).size(withAttributes: [.font: font])
        let width = max(ceil(sample.width), 1)
        let height = max(ceil(font.ascender - font.descender + font.leading), 1)
        return NSRect(
            x: CGFloat(column) * width,
            y: bounds.height - CGFloat(row + 1) * height,
            width: width,
            height: height
        )
    }

    private func styledMarkedText(_ source: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return text }
        text.addAttributes([
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineColor: nativeForegroundColor,
        ], range: full)
        text.enumerateAttribute(.underlineStyle, in: full) { value, range, _ in
            if value == nil {
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        let selected = NSIntersectionRange(markedSelection, full)
        if markedSelection.location != NSNotFound, selected.length > 0 {
            text.addAttribute(.backgroundColor, value: nativeForegroundColor.withAlphaComponent(0.22), range: selected)
        }
        return text
    }

    private static func markedString(from string: Any) -> NSAttributedString {
        if let attributed = string as? NSAttributedString {
            return attributed
        }
        if let text = string as? String {
            return NSAttributedString(string: text)
        }
        return NSAttributedString()
    }

    private static func resolve(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }
}
