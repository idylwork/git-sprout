import AppKit
import SwiftUI

struct DiffView: View {
    var document: DiffDocument?
    var isLoading: Bool
    var emptyText: String = String(localized: "No Differences")
    var hunkStaged: Bool? = nil
    var primaryTitle: String?
    var secondaryTitle: String?
    var actionsEnabled: Bool = true
    var onPrimary: ((DiffHunk) -> Void)?
    var onSecondary: ((DiffHunk) -> Void)?
    var onStageLines: ((String) -> Void)? = nil
    /// 作業ツリーまたはインデックスの末尾に、足りない改行を足す。
    var onFixMissingNewline: (() -> Void)? = nil

    @AppStorage(AppSettings.wrapDiffLinesKey) private var wrapLines = false
    @State private var selectedLineIDs: Set<Int> = []
    @State private var selectionAnchor: Int?
    @State private var lineScroll = ScrollPosition(idType: Never.self, x: 0)

    private static let lineFontSize: CGFloat = 12
    private static let lineHeight = ceil(
        NSFont.monospacedSystemFont(ofSize: lineFontSize, weight: .regular).boundingRectForFont.height
    )

    var body: some View {
        Group {
            if isLoading && document == nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                if document.truncated {
                    unavailable(String(localized: "Diff is too large to display."), systemImage: "exclamationmark.triangle")
                } else if document.hasImageDiff, ImageDiffView.canDisplay(before: document.beforeImage, after: document.afterImage) {
                    VStack(spacing: 0) {
                        if let from = document.renameFrom {
                            renameBanner(from: from, to: document.renameTo)
                        }
                        ImageDiffView(before: document.beforeImage, after: document.afterImage)
                    }
                } else if document.binary {
                    unavailable(String(localized: "Binary File"), systemImage: "doc")
                } else if document.isEmpty {
                    unavailable(emptyText, systemImage: "doc.text")
                } else {
                    let digits = gutterDigits(in: document)
                    let gutterWidth = measuredGutterWidth(oldDigits: digits.old, newDigits: digits.new)
                    GeometryReader { proxy in
                        let viewportWidth = proxy.size.width
                        let textViewport = max(0, viewportWidth - gutterWidth)
                        let columnWidth = textColumnWidth(in: document, minimum: textViewport)
                        Group {
                            if wrapLines {
                                wrappedDocument(document, digits: digits, viewportWidth: viewportWidth, minHeight: proxy.size.height)
                            } else {
                                scrollingDocument(
                                    document,
                                    digits: digits,
                                    viewportWidth: viewportWidth,
                                    minHeight: proxy.size.height,
                                    gutterWidth: gutterWidth,
                                    textViewport: textViewport,
                                    columnWidth: columnWidth
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onChange(of: document) { _, _ in
                        selectedLineIDs = []
                        selectionAnchor = nil
                        lineScroll.scrollTo(x: 0)
                    }
                    .onChange(of: wrapLines) { _, _ in
                        lineScroll.scrollTo(x: 0)
                    }
                }
            } else {
                unavailable(String(localized: "Nothing to Show"), systemImage: "doc.text.magnifyingglass")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func renameBanner(from: String, to: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.forward")
                .foregroundStyle(.orange)
            Text(to.map { "\(from) → \($0)" } ?? from)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func hunkHeader(_ hunk: DiffHunk, document: DiffDocument) -> some View {
        let selectedCount = hunk.lines.filter { line in
            selectedLineIDs.contains(line.id) && (line.kind == .addition || line.kind == .deletion)
        }.count
        return HStack(spacing: 8) {
            if let hunkStaged, let onPrimary {
                StageCheckbox(isOn: hunkStaged, enabled: actionsEnabled) {
                    onPrimary(hunk)
                }
                .fixedSize()
            }
            Text(hunkLineLabel(hunk))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if selectedCount > 0, onStageLines != nil {
                Button(stageSelectionTitle(count: selectedCount, unstage: hunkStaged == true)) {
                    stageLines(in: hunk, document: document)
                }
                .disabled(!actionsEnabled)
                .fixedSize()
            }
            if hunkStaged == nil, let primaryTitle, let onPrimary {
                Button(primaryTitle) { onPrimary(hunk) }
                    .disabled(!actionsEnabled)
                    .fixedSize()
            }
            if let secondaryTitle, let onSecondary {
                Button(secondaryTitle, role: .destructive) { onSecondary(hunk) }
                    .disabled(!actionsEnabled)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(Color.secondary.opacity(0.12))
    }

    private func hunkLineLabel(_ hunk: DiffHunk) -> String {
        afterLineLabel(start: hunk.newStart, count: hunk.newCount)
    }

    private func afterLineLabel(start: Int, count: Int) -> String {
        if count <= 0 { return "" }
        if count == 1 { return String(localized: "Line \(start)") }
        return String(localized: "Lines \(start)-\(start + count - 1)")
    }

    private func stageSelectionTitle(count: Int, unstage: Bool) -> String {
        if unstage {
            if count == 1 { return String(localized: "Unstage 1 Line") }
            return String(localized: "Unstage \(count) Lines")
        }
        if count == 1 { return String(localized: "Stage 1 Line") }
        return String(localized: "Stage \(count) Lines")
    }

    private func wrappedDocument(
        _ document: DiffDocument,
        digits: (old: Int, new: Int),
        viewportWidth: CGFloat,
        minHeight: CGFloat
    ) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let from = document.renameFrom {
                    renameBanner(from: from, to: document.renameTo)
                        .frame(width: viewportWidth, alignment: .leading)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.hunks) { hunk in
                        hunkHeader(hunk, document: document)
                            .frame(width: viewportWidth, alignment: .leading)
                        ForEach(numbered(hunk)) { line in
                            wrappedLine(line, oldDigits: digits.old, newDigits: digits.new, viewportWidth: viewportWidth)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: viewportWidth, minHeight: minHeight, alignment: .topLeading)
        }
        .defaultScrollAnchor(.top)
    }

    private func scrollingDocument(
        _ document: DiffDocument,
        digits: (old: Int, new: Int),
        viewportWidth: CGFloat,
        minHeight: CGFloat,
        gutterWidth: CGFloat,
        textViewport: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let from = document.renameFrom {
                    renameBanner(from: from, to: document.renameTo)
                        .frame(width: viewportWidth, alignment: .leading)
                }
                ForEach(document.hunks) { hunk in
                    hunkHeader(hunk, document: document)
                        .frame(width: viewportWidth, alignment: .leading)
                    HStack(alignment: .top, spacing: 0) {
                        gutterColumn(hunk, digits: digits, width: gutterWidth)
                        ScrollView(.horizontal) {
                            textColumn(hunk, width: columnWidth)
                        }
                        .frame(width: textViewport)
                        .clipped()
                        .scrollPosition($lineScroll)
                        .scrollIndicators(.hidden, axes: .horizontal)
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    }
                    .frame(width: viewportWidth, alignment: .leading)
                }
            }
            .padding(.bottom, 12)
            .frame(width: viewportWidth, alignment: .topLeading)
            .frame(minHeight: minHeight, alignment: .topLeading)
        }
        .defaultScrollAnchor(.top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if columnWidth > textViewport + 1 {
                horizontalBar(gutterWidth: gutterWidth, columnWidth: columnWidth)
            }
        }
    }

    private func gutterColumn(
        _ hunk: DiffHunk,
        digits: (old: Int, new: Int),
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(numbered(hunk)) { line in
                gutterCell(line, oldDigits: digits.old, newDigits: digits.new)
                    .frame(width: width, height: Self.lineHeight, alignment: .leading)
                    .background(rowBackground(line))
                    .contentShape(Rectangle())
                    .onTapGesture { activate(line) }
                    .modifier(MissingNewlineHover(enabled: canFix(line)))
            }
        }
        .font(.system(size: Self.lineFontSize, design: .monospaced))
    }

    private func textColumn(_ hunk: DiffHunk, width: CGFloat) -> some View {
        let lines = numbered(hunk)
        let height = CGFloat(lines.count) * Self.lineHeight
        return ZStack(alignment: .topLeading) {
            DiffTextColumn(
                lines: lines,
                selectedIDs: selectedLineIDs,
                lineHeight: Self.lineHeight,
                fontSize: Self.lineFontSize,
                onSelect: { activate($0) },
                onFixMissingNewline: actionsEnabled ? onFixMissingNewline : nil
            )
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if line.missingNewline != nil {
                    Image(systemName: "minus.circle")
                        .font(.system(size: Self.lineFontSize))
                        .foregroundStyle(line.missingNewline == .missing ? .red : .primary)
                        .accessibilityHidden(true)
                        .frame(width: Self.lineFontSize, height: Self.lineHeight, alignment: .center)
                        .offset(y: CGFloat(index) * Self.lineHeight)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func horizontalBar(gutterWidth: CGFloat, columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ScrollView(.horizontal) {
                Color.clear.frame(width: columnWidth, height: 1)
            }
            .scrollPosition($lineScroll)
            .scrollIndicators(.visible, axes: .horizontal)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: 16)
    }

    private func gutterCell(_ line: NumberedDiffLine, oldDigits: Int, newDigits: Int) -> some View {
        HStack(spacing: 8) {
            Text(gutter(line.oldNumber, width: oldDigits))
                .foregroundStyle(.secondary)
            Text(gutter(line.newNumber, width: newDigits))
                .foregroundStyle(.secondary)
            Text(markerText(line))
                .foregroundStyle(markerColor(line))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func wrappedLine(
        _ line: NumberedDiffLine,
        oldDigits: Int,
        newDigits: Int,
        viewportWidth: CGFloat
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(gutter(line.oldNumber, width: oldDigits))
                    .foregroundStyle(.secondary)
                Text(gutter(line.newNumber, width: newDigits))
                    .foregroundStyle(.secondary)
                Text(markerText(line))
                    .foregroundStyle(markerColor(line))
            }
            .contentShape(Rectangle())
            .onTapGesture { activate(line) }
            wrappedLineText(line)
        }
        .font(.system(size: Self.lineFontSize, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(width: viewportWidth, alignment: .leading)
        .background(rowBackground(line))
        .modifier(MissingNewlineHover(enabled: canFix(line)))
    }

    @ViewBuilder
    private func wrappedLineText(_ line: NumberedDiffLine) -> some View {
        if line.missingNewline != nil {
            HStack(spacing: 4) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(line.missingNewline == .missing ? .red : .primary)
                    .accessibilityHidden(true)
                Text(verbatim: NoNewlineAtEOFMarker.title)
                    .foregroundStyle(line.missingNewline == .missing ? .red : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture { activate(line) }
        } else {
            Text(line.line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func measuredGutterWidth(oldDigits: Int, newDigits: Int) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Self.lineFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func width(of string: String) -> CGFloat {
            ceil((string as NSString).size(withAttributes: attributes).width)
        }
        return 8
            + width(of: String(repeating: "0", count: max(oldDigits, 1)))
            + 8
            + width(of: String(repeating: "0", count: max(newDigits, 1)))
            + 8
            + width(of: "+")
            + 8
    }

    private func textColumnWidth(in document: DiffDocument, minimum: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Self.lineFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var longest: CGFloat = 0
        for hunk in document.hunks {
            for line in hunk.lines {
                let measured: CGFloat
                if line.kind == .meta, line.text == NoNewlineAtEOFMarker.rawLine {
                    let title = NoNewlineAtEOFMarker.title as NSString
                    measured = ceil(title.size(withAttributes: attributes).width)
                        + DiffColumnTextView.missingNewlineIndent
                } else {
                    measured = ceil((line.text as NSString).size(withAttributes: attributes).width)
                }
                longest = max(longest, measured)
            }
        }
        return max(minimum, longest + 12)
    }

    private func stageLines(in hunk: DiffHunk, document: DiffDocument) {
        let ids = Set(hunk.lines.map(\.id)).intersection(selectedLineIDs)
        guard actionsEnabled, let patch = PartialPatchBuilder.make(document: document, selectedIDs: ids) else { return }
        selectedLineIDs.subtract(ids)
        if selectedLineIDs.isEmpty {
            selectionAnchor = nil
        }
        onStageLines?(patch)
    }

    private func canFix(_ line: NumberedDiffLine) -> Bool {
        actionsEnabled && line.missingNewline == .missing && onFixMissingNewline != nil
    }

    private func activate(_ line: NumberedDiffLine) {
        if canFix(line) {
            onFixMissingNewline?()
            return
        }
        select(line)
    }

    private func markerText(_ line: NumberedDiffLine) -> String {
        if line.missingNewline == .resolved { return "-" }
        return line.line.prefix.isEmpty ? " " : line.line.prefix
    }

    private func markerColor(_ line: NumberedDiffLine) -> Color {
        if line.missingNewline == .resolved { return .red }
        return markerColor(for: line.line.kind)
    }

    private func select(_ line: NumberedDiffLine) {
        guard actionsEnabled, onStageLines != nil else { return }
        guard line.line.kind == .addition || line.line.kind == .deletion else {
            if !NSEvent.modifierFlags.contains(.shift), !NSEvent.modifierFlags.contains(.command) {
                selectedLineIDs = []
                selectionAnchor = nil
            }
            return
        }
        let id = line.line.id
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let selectionAnchor, let ids = changeLineIDs() {
            if let start = ids.firstIndex(of: selectionAnchor), let end = ids.firstIndex(of: id) {
                selectedLineIDs = Set(ids[min(start, end)...max(start, end)])
            }
        } else if flags.contains(.command) {
            if selectedLineIDs.contains(id) {
                selectedLineIDs.remove(id)
            } else {
                selectedLineIDs.insert(id)
            }
            selectionAnchor = id
        } else {
            selectedLineIDs = [id]
            selectionAnchor = id
        }
    }

    private func changeLineIDs() -> [Int]? {
        document?.hunks.flatMap { hunk in
            hunk.lines.compactMap { line in
                line.kind == .addition || line.kind == .deletion ? line.id : nil
            }
        }
    }

    private func rowBackground(_ line: NumberedDiffLine) -> Color {
        diffRowColor(
            kind: line.line.kind,
            missingNewline: line.missingNewline,
            selected: selectedLineIDs.contains(line.line.id)
        )
    }

    private func numbered(_ hunk: DiffHunk) -> [NumberedDiffLine] {
        var old = hunk.oldStart
        var new = hunk.newStart
        var previous: DiffLine.Kind?
        return hunk.lines.map { line in
            let note = NoNewlineAtEOFMarker.state(of: line, previous: previous)
            if line.kind != .meta {
                previous = line.kind
            }
            switch line.kind {
            case .context:
                let item = NumberedDiffLine(line: line, oldNumber: old, newNumber: new, missingNewline: note)
                old += 1
                new += 1
                return item
            case .deletion:
                let item = NumberedDiffLine(line: line, oldNumber: old, newNumber: nil, missingNewline: note)
                old += 1
                return item
            case .addition:
                let item = NumberedDiffLine(line: line, oldNumber: nil, newNumber: new, missingNewline: note)
                new += 1
                return item
            case .meta:
                return NumberedDiffLine(line: line, oldNumber: nil, newNumber: nil, missingNewline: note)
            }
        }
    }

    private func gutterDigits(in document: DiffDocument) -> (old: Int, new: Int) {
        var oldMax = 1
        var newMax = 1
        for hunk in document.hunks {
            oldMax = max(oldMax, hunk.oldStart + max(hunk.oldCount - 1, 0))
            newMax = max(newMax, hunk.newStart + max(hunk.newCount - 1, 0))
        }
        return (max(String(oldMax).count, 1), max(String(newMax).count, 1))
    }

    private func gutter(_ value: Int?, width: Int) -> String {
        guard let value else { return String(repeating: " ", count: width) }
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: " ", count: width - text.count) + text
    }

    private func markerColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .context, .meta: return .secondary
        }
    }

    private func unavailable(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 差分の本文。行の高さはガターと揃え、ドラッグした範囲はコピーできる。
private struct DiffTextColumn: NSViewRepresentable {
    var lines: [NumberedDiffLine]
    var selectedIDs: Set<Int>
    var lineHeight: CGFloat
    var fontSize: CGFloat
    var onSelect: (NumberedDiffLine) -> Void
    var onFixMissingNewline: (() -> Void)?

    func makeNSView(context: Context) -> DiffColumnTextView {
        DiffColumnTextView()
    }

    func updateNSView(_ view: DiffColumnTextView, context: Context) {
        view.onSelect = onSelect
        view.onFixMissingNewline = onFixMissingNewline
        view.show(
            lines: lines,
            selectedIDs: selectedIDs,
            fontSize: fontSize,
            lineHeight: lineHeight,
            width: view.bounds.width
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffColumnTextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: CGFloat(lines.count) * lineHeight)
    }
}

final class DiffColumnTextView: NSTextView {
    var lineHeight: CGFloat = 0
    var onSelect: (NumberedDiffLine) -> Void = { _ in }
    var onFixMissingNewline: (() -> Void)?
    private var records: [NumberedDiffLine] = []
    private var selectedIDs: Set<Int> = []
    private var appliedText: String?
    private var hoverTracking: NSTrackingArea?

    override var isOpaque: Bool { false }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        usesFindBar = false
        usesFontPanel = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        lines: [NumberedDiffLine],
        selectedIDs: Set<Int>,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        width: CGFloat
    ) {
        records = lines
        self.selectedIDs = selectedIDs
        self.lineHeight = lineHeight
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let parts = lines.map { line -> (text: String, red: Bool, indent: CGFloat) in
            guard let note = line.missingNewline else {
                return (line.line.text, false, 0)
            }
            return (NoNewlineAtEOFMarker.title, note == .missing, Self.missingNewlineIndent)
        }
        apply(parts: parts, font: font, lineHeight: lineHeight, width: width)
        needsDisplay = true
    }

    /// 行頭アイコンと文字の重なりを避ける字下げ。
    static let missingNewlineIndent: CGFloat = 16

    func apply(texts: [String], font: NSFont, lineHeight: CGFloat, width: CGFloat) {
        apply(parts: texts.map { ($0, false, 0) }, font: font, lineHeight: lineHeight, width: width)
    }

    func apply(parts: [(text: String, red: Bool, indent: CGFloat)], font: NSFont, lineHeight: CGFloat, width: CGFloat) {
        self.lineHeight = lineHeight
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.lineBreakMode = .byClipping
        func attributes(red: Bool, indent: CGFloat) -> [NSAttributedString.Key: Any] {
            let paragraph = style.mutableCopy() as! NSMutableParagraphStyle
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            return [
                .font: font,
                .foregroundColor: red ? NSColor.systemRed : NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        }
        let key = parts.map { "\($0.red ? "r" : "k")\($0.indent)\($0.text)" }.joined(separator: "\n")
        if key != appliedText {
            let storage = NSMutableAttributedString()
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    storage.append(NSAttributedString(string: "\n", attributes: attributes(red: false, indent: 0)))
                }
                storage.append(NSAttributedString(string: part.text, attributes: attributes(red: part.red, indent: part.indent)))
            }
            textStorage?.setAttributedString(storage)
            appliedText = key
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        let containerWidth = max(width, bounds.width, 1)
        textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager?.ensureLayout(for: textContainer!)
    }

    func lineFragmentOrigins() -> [CGFloat] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        layout.ensureLayout(for: container)
        var origins: [CGFloat] = []
        var index = 0
        let count = layout.numberOfGlyphs
        while index < count {
            var range = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range, withoutAdditionalLayout: true)
            origins.append(rect.origin.y)
            let next = NSMaxRange(range)
            if next <= index { break }
            index = next
        }
        return origins
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLineBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if fixable(at: event) {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let fixing = fixable(at: event)
        let tip = fixing ? String(localized: "Add a newline at the end of the file") : nil
        if toolTip != tip { toolTip = tip }
        if fixing {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        toolTip = nil
    }

    override func mouseDown(with event: NSEvent) {
        let index = lineIndex(for: event)
        let fixing = isFixable(index)
        let previous = window?.firstResponder
        super.mouseDown(with: event)
        guard selectedRange().length == 0 else { return }
        if fixing {
            onFixMissingNewline?()
        } else if let index {
            onSelect(records[index])
        } else {
            return
        }
        if let previous, previous !== self {
            window?.makeFirstResponder(previous)
        }
    }

    private func lineIndex(for event: NSEvent) -> Int? {
        guard lineHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor(point.y / lineHeight))
        guard records.indices.contains(index) else { return nil }
        return index
    }

    private func fixable(at event: NSEvent) -> Bool {
        isFixable(lineIndex(for: event))
    }

    private func isFixable(_ index: Int?) -> Bool {
        guard let index, onFixMissingNewline != nil else { return false }
        return records[index].missingNewline == .missing
    }

    private func drawLineBackgrounds(in dirty: NSRect) {
        guard lineHeight > 0 else { return }
        for (index, line) in records.enumerated() {
            let rect = NSRect(x: 0, y: CGFloat(index) * lineHeight, width: bounds.width, height: lineHeight)
            guard rect.intersects(dirty) else { continue }
            let color = fillColor(for: line)
            guard color.alphaComponent > 0.001 else { continue }
            color.setFill()
            rect.fill()
        }
    }

    private func fillColor(for line: NumberedDiffLine) -> NSColor {
        NSColor(diffRowColor(
            kind: line.line.kind,
            missingNewline: line.missingNewline,
            selected: selectedIDs.contains(line.id)
        ))
    }
}

struct NumberedDiffLine: Identifiable {
    var line: DiffLine
    var oldNumber: Int?
    var newNumber: Int?
    var missingNewline: NoNewlineAtEOFMarker?

    var id: Int { line.id }
}

fileprivate func diffRowColor(kind: DiffLine.Kind, missingNewline: NoNewlineAtEOFMarker?, selected: Bool) -> Color {
    if selected { return Color.accentColor.opacity(0.35) }
    if missingNewline == .resolved { return Color.red.opacity(0.16) }
    switch kind {
    case .addition: return Color.green.opacity(0.16)
    case .deletion: return Color.red.opacity(0.16)
    case .meta: return Color.secondary.opacity(0.08)
    case .context: return .clear
    }
}

private struct MissingNewlineHover: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .help("Add a newline at the end of the file")
                .onHover { inside in
                    if inside {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
        } else {
            content
        }
    }
}
