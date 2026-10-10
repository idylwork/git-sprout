import Foundation

/// 読み込み済みのコミットと、次ページへ持ち越すレーンだけでグラフを組む。
nonisolated struct GraphLane: Sendable, Equatable {
    var oid: String
    var color: Int
}

nonisolated struct GraphEdge: Sendable, Equatable {
    var fromLane: Int
    var toLane: Int
    var color: Int
    /// 上から来た分岐を、このコミットの丸で合流させる。
    var joinsCommit = false
}

nonisolated struct GraphRow: Identifiable, Sendable, Equatable {
    var commit: CommitRecord
    var commitLane: Int
    var commitColor: Int
    var connectsUp: Bool
    var laneCount: Int
    var edges: [GraphEdge]
    var outgoing: [GraphLane]

    var id: String { commit.oid }
}

nonisolated struct GraphCursor: Sendable, Equatable {
    var lanes: [GraphLane]
    var nextColor: Int

    static let empty = GraphCursor(lanes: [], nextColor: 0)
}

nonisolated struct GraphLayoutResult: Sendable {
    var rows: [GraphRow]
    var cursor: GraphCursor
}

nonisolated enum GraphLayout {
    /// `head` を渡すと、そのコミットが現れるまで左端のレーンを空けておく。
    static func layout(commits: [CommitRecord], cursor: GraphCursor, head: String = "") -> GraphLayoutResult {
        var lanes = cursor.lanes
        var nextColor = cursor.nextColor
        if cursor == .empty, !head.isEmpty, let first = commits.first?.oid, first != head {
            lanes = [GraphLane(oid: head, color: 0)]
            nextColor = 1
        }
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            rows.append(place(commit, lanes: &lanes, nextColor: &nextColor))
        }
        return GraphLayoutResult(rows: rows, cursor: GraphCursor(lanes: lanes, nextColor: nextColor))
    }

    /// 作業ツリーの行は常にグラフの先頭に置く。線は左端のチェックアウト中のコミットへ伸ばす。
    static func insertingUncommitted(_ rows: [GraphRow], aboveHead oid: String) -> [GraphRow] {
        if rows.isEmpty {
            return [uncommittedRow(parents: [], lane: 0, color: 0, edges: [], outgoing: [], laneCount: 1)]
        }
        guard !oid.isEmpty, let index = rows.firstIndex(where: { $0.commit.oid == oid }) else {
            if let lane = reservedLane(in: rows, oid: oid) {
                let color = rows[0].edges.first { $0.fromLane == lane && $0.toLane == lane }?.color ?? 0
                let synthetic = uncommittedRow(
                    parents: [oid],
                    lane: lane,
                    color: color,
                    edges: [GraphEdge(fromLane: lane, toLane: lane, color: color)],
                    outgoing: [],
                    laneCount: max(rows[0].laneCount, lane + 1)
                )
                return [synthetic] + rows
            }
            let lane = rows[0].laneCount
            let floating = uncommittedRow(parents: [], lane: lane, color: 0, edges: [], outgoing: [], laneCount: lane + 1)
            return [floating] + rows
        }

        var rows = rows
        let headLane = rows[index].commitLane
        let headColor = rows[index].commitColor
        let openToTheTop = index == 0 || (
            rows[index].connectsUp
                && rows[..<index].allSatisfy { $0.commitLane != headLane }
                && rows[0].edges.contains { $0.fromLane == headLane && $0.toLane == headLane }
        )
        if openToTheTop {
            let synthetic = uncommittedRow(
                parents: [rows[index].commit.oid],
                lane: headLane,
                color: headColor,
                edges: [GraphEdge(fromLane: headLane, toLane: headLane, color: headColor)],
                outgoing: [],
                laneCount: max(rows[0].laneCount, headLane + 1)
            )
            if index == 0 {
                rows[0].connectsUp = true
            }
            return [synthetic] + rows
        }

        let side = rows[0...index].map(\.laneCount).max() ?? 0
        for offset in 0..<index {
            let toLane = offset == index - 1 ? headLane : side
            rows[offset].edges.append(GraphEdge(fromLane: side, toLane: toLane, color: headColor))
            rows[offset].laneCount = max(rows[offset].laneCount, side + 1, toLane + 1)
        }
        rows[index].connectsUp = true
        let synthetic = uncommittedRow(
            parents: [rows[index].commit.oid],
            lane: side,
            color: headColor,
            edges: [GraphEdge(fromLane: side, toLane: side, color: headColor)],
            outgoing: [],
            laneCount: side + 1
        )
        return [synthetic] + rows
    }

    /// 未コミット行がないとき、チェックアウト中のコミット用に空けたレーンの上向きの線は描かない。
    /// レーン自体は残す。変更ができたときに列がずれないようにするため。
    static func omittingUnusedHeadLine(_ rows: [GraphRow], head oid: String) -> [GraphRow] {
        guard !oid.isEmpty,
              let index = rows.firstIndex(where: { $0.commit.oid == oid }),
              index > 0 else { return rows }
        let lane = rows[index].commitLane
        let above = rows[..<index]
        guard above.allSatisfy({ $0.commitLane != lane }),
              above.allSatisfy({ row in
                  row.edges.contains { $0.fromLane == lane && $0.toLane == lane && !$0.joinsCommit }
              }) else { return rows }

        var rows = rows
        for offset in 0..<index {
            rows[offset].edges.removeAll { $0.fromLane == lane && $0.toLane == lane && !$0.joinsCommit }
        }
        rows[index].connectsUp = false
        return rows
    }

    /// まだ描いていないチェックアウト先へ、先頭からまっすぐ続いているレーン。
    private static func reservedLane(in rows: [GraphRow], oid: String) -> Int? {
        guard !oid.isEmpty, !rows.isEmpty, !rows.contains(where: { $0.commit.oid == oid }) else { return nil }
        guard let lane = rows[0].outgoing.firstIndex(where: { $0.oid == oid }),
              rows[0].edges.contains(where: { $0.fromLane == lane && $0.toLane == lane }),
              rows.allSatisfy({ $0.commitLane != lane }) else { return nil }
        return lane
    }

    private static func uncommittedRow(
        parents: [String],
        lane: Int,
        color: Int,
        edges: [GraphEdge],
        outgoing: [GraphLane],
        laneCount: Int
    ) -> GraphRow {
        GraphRow(
            commit: CommitRecord(
                oid: CommitRecord.uncommittedOID,
                parents: parents,
                subject: "Uncommitted changes"
            ),
            commitLane: lane,
            commitColor: color,
            connectsUp: false,
            laneCount: laneCount,
            edges: edges,
            outgoing: outgoing
        )
    }

    private static func place(_ commit: CommitRecord, lanes: inout [GraphLane], nextColor: inout Int) -> GraphRow {
        let connectsUp = lanes.contains { $0.oid == commit.oid }
        if !connectsUp {
            lanes.append(GraphLane(oid: commit.oid, color: nextColor))
            nextColor += 1
        }
        let commitLane = lanes.firstIndex { $0.oid == commit.oid } ?? 0
        let commitColor = lanes[commitLane].color
        let incoming = lanes

        var outgoing: [GraphLane] = []
        var edges: [GraphEdge] = []
        let parents = commit.parents
        // 同じコミットへ向かう別レーンは、ここでは消さず丸の位置で合流させる
        let joining = incoming.indices.filter { $0 != commitLane && incoming[$0].oid == commit.oid }

        if parents.isEmpty {
            passThrough(incoming, skipping: commitLane, also: joining, outgoing: &outgoing, edges: &edges)
        } else {
            for (index, lane) in incoming.enumerated() where !joining.contains(index) {
                if index == commitLane {
                    outgoing.append(GraphLane(oid: parents[0], color: commitColor))
                    edges.append(GraphEdge(fromLane: index, toLane: outgoing.count - 1, color: commitColor))
                } else {
                    outgoing.append(lane)
                    edges.append(GraphEdge(fromLane: index, toLane: outgoing.count - 1, color: lane.color))
                }
            }
            addExtraParents(
                parents.dropFirst(),
                commitLane: commitLane,
                preferredInsert: min(commitLane + 1, outgoing.count),
                outgoing: &outgoing,
                edges: &edges,
                nextColor: &nextColor
            )
        }
        for index in joining {
            edges.append(GraphEdge(fromLane: index, toLane: commitLane, color: incoming[index].color, joinsCommit: true))
        }

        lanes = outgoing
        let laneCount = max(incoming.count, outgoing.count, commitLane + 1)
        return GraphRow(
            commit: commit,
            commitLane: commitLane,
            commitColor: commitColor,
            connectsUp: connectsUp,
            laneCount: laneCount,
            edges: edges,
            outgoing: outgoing
        )
    }

    private static func passThrough(
        _ incoming: [GraphLane],
        skipping commitLane: Int,
        also skippingExtra: [Int] = [],
        outgoing: inout [GraphLane],
        edges: inout [GraphEdge]
    ) {
        for (index, lane) in incoming.enumerated() where index != commitLane && !skippingExtra.contains(index) {
            edges.append(GraphEdge(fromLane: index, toLane: outgoing.count, color: lane.color))
            outgoing.append(lane)
        }
    }

    private static func addExtraParents(
        _ parents: ArraySlice<String>,
        commitLane: Int,
        preferredInsert: Int,
        outgoing: inout [GraphLane],
        edges: inout [GraphEdge],
        nextColor: inout Int
    ) {
        var insertAt = preferredInsert
        for parent in parents {
            if let existing = outgoing.firstIndex(where: { $0.oid == parent }) {
                edges.append(GraphEdge(fromLane: commitLane, toLane: existing, color: outgoing[existing].color))
                continue
            }
            let index = min(insertAt, outgoing.count)
            let lane = GraphLane(oid: parent, color: nextColor)
            nextColor += 1
            outgoing.insert(lane, at: index)
            for edgeIndex in edges.indices where edges[edgeIndex].toLane >= index {
                edges[edgeIndex].toLane += 1
            }
            edges.append(GraphEdge(fromLane: commitLane, toLane: index, color: lane.color))
            insertAt = index + 1
        }
    }
}
