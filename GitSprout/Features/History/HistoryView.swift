import SwiftUI

struct HistoryView: View {
    var session: WorkspaceSession
    @Environment(\.keyboardFocus) private var keyboardFocus
    @State private var appliedFocus = 0
    @Namespace private var refChips

    /// ブランチがどのコミットにあるか。変わったときだけチップを動かす。
    private var refPlacement: [String: [String]] {
        var placement: [String: [String]] = [:]
        for row in session.historyRows where !row.commit.refs.isEmpty {
            placement[row.id] = row.commit.refs
        }
        return placement
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.historyLoading && session.graphRows.isEmpty {
                ProgressView("Loading History…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.historyRows.isEmpty {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.historyRows) { row in
                                HistoryRow(
                                    row: row,
                                    isSelected: session.selectedCommit == row.id,
                                    caption: row.id == CommitRecord.uncommittedOID ? uncommittedCaption : nil,
                                    refChips: refChips
                                )
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        keyboardFocus?.target = .commits
                                        guard session.selectedCommit != row.id else { return }
                                        Task { await session.selectCommit(row.id) }
                                    }
                                    .contextMenu {
                                        if row.id != CommitRecord.uncommittedOID {
                                            CommitContextMenu(
                                                items: session.commitMenu(for: row.commit),
                                                isMutating: session.isMutating
                                            )
                                        }
                                    }
                                    .onAppear {
                                        if row.id != CommitRecord.uncommittedOID {
                                            Task { await session.prefetchHistory(oid: row.id) }
                                        }
                                    }
                            }
                            if session.historyHasMore {
                                Button(String(localized: session.historyLoadingMore ? "Loading…" : "Load More")) {
                                    Task { await session.loadMoreHistory() }
                                }
                                .disabled(session.historyLoadingMore)
                                .padding(8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.35), value: refPlacement)
                    }
                    .keyboardTarget(.commits, focusable: true)
                    .selectionArrows(target: .commits) { delta, _ in
                        moveCommit(delta)
                    }
                    .onAppear { scrollToFocus(proxy) }
                    .onChange(of: session.historyFocus) { _, _ in
                        scrollToFocus(proxy)
                    }
                    .onChange(of: session.graphRows.count) { _, _ in
                        scrollToFocus(proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moveCommit(_ delta: Int) {
        let ids = session.historyRows.map(\.id)
        guard let index = ListSelectionMover.index(of: session.selectedCommit, in: ids, delta: delta) else { return }
        let oid = ids[index]
        guard oid != session.selectedCommit else { return }
        session.revealHistory(oid)
        Task { await session.selectCommit(oid) }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let focus = session.historyFocus, focus.token != appliedFocus else { return }
        guard session.historyRows.contains(where: { $0.id == focus.oid }) else { return }
        appliedFocus = focus.token
        proxy.scrollTo(focus.oid, anchor: .center)
    }

    private var uncommittedCaption: String {
        if session.changeCount == 1 { return String(localized: "1 change") }
        return String(localized: "\(session.changeCount) changes")
    }
}

extension WorkspaceSession {
    /// コミット詳細の見出しメニューと履歴行の右クリックメニューで共有する項目。
    func commitMenu(for commit: CommitRecord) -> [SectionMenuItem] {
        let isCheckedOut = !head.oid.isEmpty && commit.oid == head.oid
        var menu = [
            SectionMenuItem(
                id: "checkout",
                title: String(localized: "Checkout"),
                action: { Task { await self.checkoutCommit(commit) } }
            ),
            SectionMenuItem(
                id: "diff",
                title: String(localized: "View Diff from Here"),
                disabled: head.oid.isEmpty || isCheckedOut,
                action: {
                    Task {
                        // 範囲 Diff は選択中のコミットを起点にするため、右クリックした行を先に選ぶ
                        if self.selectedCommit != commit.oid {
                            await self.selectCommit(commit.oid)
                        }
                        await self.showRangeDiff()
                    }
                }
            )
        ]
        if isCheckedOut {
            menu.append(
                SectionMenuItem(
                    id: "undo",
                    title: String(localized: "Undo Commit"),
                    destructive: true,
                    disabled: commit.parents.isEmpty,
                    dividerBefore: true,
                    action: { self.confirmUndoCommit() }
                )
            )
        }
        return menu
    }
}

/// 履歴行の右クリックメニュー。
private struct CommitContextMenu: View {
    var items: [SectionMenuItem]
    var isMutating: Bool

    var body: some View {
        ForEach(items) { item in
            if item.dividerBefore {
                Divider()
            }
            Button(item.title, role: item.destructive ? .destructive : nil, action: item.action)
                .disabled(item.disabled || isMutating)
        }
    }
}

/// 件名の下に本文を出す。短いときは高さに沿い、長いときはこの中だけスクロールする。
private struct CommitMessageBody: View {
    var text: String
    private let maxHeight: CGFloat = 160
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CommitBodyHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(CommitBodyHeightKey.self) { contentHeight = $0 }
    }
}

private struct CommitBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SelectableText: View {
    var text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            .textSelection(.enabled)
            .lineLimit(monospaced ? 2 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum HistoryMetrics {
    static let rowHeight: CGFloat = 28

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct HistoryRow: View {
    var row: GraphRow
    var isSelected: Bool
    var caption: String? = nil
    var refChips: Namespace.ID

    private var isUncommitted: Bool { row.commit.oid == CommitRecord.uncommittedOID }

    private var subjectText: String {
        if isUncommitted { return String(localized: "Uncommitted changes") }
        if row.commit.subject.isEmpty { return String(localized: "(No message)") }
        return row.commit.subject
    }

    var body: some View {
        HStack(spacing: 8) {
            GraphGlyphs(row: row, muted: isUncommitted)
            Text(subjectText)
                .foregroundStyle(isUncommitted ? Color.secondary : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !isUncommitted {
                if !row.commit.refs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(row.commit.refs, id: \.self) { ref in
                            RefChip(name: ref)
                                // 同じ名前のチップを行をまたいで対応させ、付け替え時にスライドさせる
                                .matchedGeometryEffect(id: ref, in: refChips)
                        }
                    }
                    .fixedSize()
                }
                Spacer(minLength: 8)
                Text(HistoryMetrics.dateFormatter.string(from: row.commit.authoredAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if isUncommitted {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: HistoryMetrics.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

private struct RefChip: View {
    var name: String

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

private struct GraphGlyphs: View {
    var row: GraphRow
    var muted = false
    private let laneWidth: CGFloat = 14
    private let rowHeight: CGFloat = HistoryMetrics.rowHeight

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            func xPosition(_ lane: Int) -> CGFloat {
                (CGFloat(lane) + 0.5) * laneWidth
            }
            if row.connectsUp {
                var stem = Path()
                stem.move(to: CGPoint(x: xPosition(row.commitLane), y: 0))
                stem.addLine(to: CGPoint(x: xPosition(row.commitLane), y: midY))
                context.stroke(stem, with: .color(ink(row.commitColor, forCommit: true)), lineWidth: 1.5)
            }
            for edge in row.edges {
                var path = Path()
                let startX = xPosition(edge.fromLane)
                let endX = xPosition(edge.toLane)
                let startY: CGFloat = edge.fromLane == row.commitLane ? midY : 0
                path.move(to: CGPoint(x: startX, y: startY))
                if edge.joinsCommit {
                    // 前のコミットの丸から伸びてきた色を、この丸まで保って合流する
                    let drop = min(max(abs(endX - startX) * 0.75, 8), 12)
                    let bendStart = max(startY, midY - drop)
                    if bendStart > startY + 0.5 {
                        path.addLine(to: CGPoint(x: startX, y: bendStart))
                    }
                    path.addCurve(
                        to: CGPoint(x: endX, y: midY),
                        control1: CGPoint(x: startX, y: midY),
                        control2: CGPoint(x: endX, y: bendStart)
                    )
                } else if abs(startX - endX) < 0.5 {
                    path.addLine(to: CGPoint(x: endX, y: size.height))
                } else {
                    let drop = min(max(abs(endX - startX) * 0.75, 8), 12)
                    let bendY = min(size.height, startY + drop)
                    path.addCurve(
                        to: CGPoint(x: endX, y: bendY),
                        control1: CGPoint(x: startX, y: bendY),
                        control2: CGPoint(x: endX, y: startY + drop * 0.45)
                    )
                    if bendY < size.height - 0.5 {
                        path.addLine(to: CGPoint(x: endX, y: size.height))
                    }
                }
                let ownsCommit = edge.fromLane == row.commitLane
                context.stroke(path, with: .color(ink(edge.color, forCommit: ownsCommit)), lineWidth: 1.5)
            }
            let dot = CGRect(x: xPosition(row.commitLane) - 3.5, y: midY - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(ink(row.commitColor, forCommit: true)))
        }
        .frame(width: CGFloat(max(row.laneCount, 1)) * laneWidth, height: rowHeight)
    }

    private func ink(_ index: Int, forCommit: Bool) -> Color {
        if muted && forCommit { return Color.secondary }
        return GraphPalette.color(index)
    }
}

private enum GraphPalette {
    static func color(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .cyan, .indigo]
        let wrapped = ((index % colors.count) + colors.count) % colors.count
        return colors[wrapped]
    }
}

struct HistoryDetailView: View {
    var session: WorkspaceSession

    private var showsCommit: Bool {
        guard let oid = session.selectedCommit else { return false }
        return oid != CommitRecord.uncommittedOID
    }

    var body: some View {
        Group {
            if showsCommit {
                ChangedFilesSplit(
                    files: session.commitFiles,
                    filesCapped: session.commitFilesCapped,
                    filesLoading: session.commitFilesLoading,
                    listID: session.selectedCommit ?? "commit",
                    selectedPath: session.selectedCommitPath,
                    document: session.commitDiff,
                    diffLoading: session.commitDiffLoading,
                    isMutating: session.isMutating,
                    commitOID: session.selectedCommit,
                    onSelect: { path in
                        Task { await session.selectCommitFile(path) }
                    },
                    onOpenHistory: { path in
                        Task { await session.openFileHistory(path) }
                    },
                    sectionTitle: String(localized: "Committed Files"),
                    menu: commitFileMenu
                ) {
                    commitFilesHeader
                }
            } else {
                HSplitView {
                    ChangesView(session: session)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    ChangesDiffView(session: session)
                        .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { session.showsRangeDiff },
                set: { if !$0 { session.dismissRangeDiff() } }
            )
        ) {
            RangeDiffSheet(session: session)
        }
    }

    private var commitFileMenu: [SectionMenuItem] {
        guard let commit = session.selectedCommitRecord else { return [] }
        return session.commitMenu(for: commit)
    }

    private var commitFilesHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let commit = session.selectedCommitRecord {
                commitMessage(commit)
                commitMetadata(commit)
            }
        }
        .padding(10)
    }

    private func commitMessage(_ commit: CommitRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject.isEmpty ? String(localized: "(No message)") : commit.subject)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !commit.body.isEmpty {
                CommitMessageBody(text: commit.body)
            }
        }
    }

    private func commitMetadata(_ commit: CommitRecord) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            detailRow("Commit ID", commit.oid, monospaced: true)
            detailRow("Date", commit.authoredAt.formatted(date: .abbreviated, time: .shortened))
            if !commit.authorName.isEmpty {
                detailRow("Author", commit.authorName)
            }
            if !commit.decoration.isEmpty {
                detailRow("Refs", commit.decoration)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            SelectableText(text: value, monospaced: monospaced)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
