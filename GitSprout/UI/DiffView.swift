//
//  DiffView.swift
//  GitSprout
//

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
                    .onTapGesture { select(line) }
            }
        }
        .font(.system(size: Self.lineFontSize, design: .monospaced))
    }

    private func textColumn(_ hunk: DiffHunk, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(numbered(hunk)) { line in
                Text(line.line.text)
                    .lineLimit(1)
                    .frame(width: width, height: Self.lineHeight, alignment: .leading)
                    .background(rowBackground(line))
                    .contentShape(Rectangle())
                    .onTapGesture { select(line) }
            }
        }
        .font(.system(size: Self.lineFontSize, design: .monospaced))
        .frame(width: width, alignment: .leading)
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
            Text(line.line.prefix.isEmpty ? " " : line.line.prefix)
                .foregroundStyle(markerColor(for: line.line.kind))
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
            Text(gutter(line.oldNumber, width: oldDigits))
                .foregroundStyle(.secondary)
            Text(gutter(line.newNumber, width: newDigits))
                .foregroundStyle(.secondary)
            Text(line.line.prefix)
                .foregroundStyle(markerColor(for: line.line.kind))
            Text(line.line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: Self.lineFontSize, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(width: viewportWidth, alignment: .leading)
        .background(rowBackground(line))
        .contentShape(Rectangle())
        .onTapGesture { select(line) }
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
                longest = max(longest, ceil((line.text as NSString).size(withAttributes: attributes).width))
            }
        }
        return max(minimum, longest + 12)
    }

    private func stageLines(in hunk: DiffHunk, document: DiffDocument) {
        let ids = Set(hunk.lines.map(\.id)).intersection(selectedLineIDs)
        guard actionsEnabled, let patch = DiffLinePatch.make(document: document, selectedIDs: ids) else { return }
        selectedLineIDs.subtract(ids)
        if selectedLineIDs.isEmpty {
            selectionAnchor = nil
        }
        onStageLines?(patch)
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
        if selectedLineIDs.contains(line.line.id) {
            return Color.accentColor.opacity(0.35)
        }
        return background(for: line.line.kind)
    }

    private func numbered(_ hunk: DiffHunk) -> [NumberedDiffLine] {
        var old = hunk.oldStart
        var new = hunk.newStart
        return hunk.lines.map { line in
            switch line.kind {
            case .context:
                let item = NumberedDiffLine(line: line, oldNumber: old, newNumber: new)
                old += 1
                new += 1
                return item
            case .deletion:
                let item = NumberedDiffLine(line: line, oldNumber: old, newNumber: nil)
                old += 1
                return item
            case .addition:
                let item = NumberedDiffLine(line: line, oldNumber: nil, newNumber: new)
                new += 1
                return item
            case .meta:
                return NumberedDiffLine(line: line, oldNumber: nil, newNumber: nil)
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

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.16)
        case .deletion: return Color.red.opacity(0.16)
        case .meta: return Color.secondary.opacity(0.08)
        case .context: return .clear
        }
    }

    private func unavailable(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NumberedDiffLine: Identifiable {
    var line: DiffLine
    var oldNumber: Int?
    var newNumber: Int?

    var id: Int { line.id }
}
