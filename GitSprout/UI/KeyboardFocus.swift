//
//  KeyboardFocus.swift
//  GitSprout
//

import SwiftUI

/// キーボードの効き先。フォーカスがある一覧だけが、上下キーで自分の選択を動かす。
enum KeyboardTarget: Hashable {
    case sidebar
    case commits
    case stashes
    case files
    case search
    case fileHistory
}

/// 一覧の選択。anchor は範囲の固定端、lead は上下キーで動く端。
nonisolated struct SelectionCursor<ID: Hashable>: Equatable {
    var selection: Set<ID>
    var anchor: ID?
    var lead: ID?
}

/// 一覧の中で上下に1つ動かす位置。端では止まる。未選択なら下で先頭、上で末尾。
nonisolated enum SelectionStep {
    static func index<ID: Equatable>(of current: ID?, in items: [ID], delta: Int) -> Int? {
        guard !items.isEmpty, delta != 0 else { return nil }
        let start: Int
        if let current, let found = items.firstIndex(of: current) {
            start = found
        } else {
            start = delta > 0 ? -1 : items.count
        }
        return min(max(0, start + delta), items.count - 1)
    }

    /// Shift を押した上下は anchor から lead までの範囲を選ぶ。Shift なしは移動先の1件だけにする。
    static func move<ID: Hashable>(
        _ cursor: SelectionCursor<ID>,
        in items: [ID],
        delta: Int,
        extending: Bool
    ) -> SelectionCursor<ID> {
        guard !items.isEmpty, delta != 0 else { return cursor }
        let origin = cursor.lead ?? sole(cursor.selection, in: items)
        let start: Int
        if let origin, let found = items.firstIndex(of: origin) {
            start = found
        } else if extending, let anchor = cursor.anchor, let found = items.firstIndex(of: anchor) {
            start = found
        } else if let edge = edge(cursor.selection, in: items, delta: delta) {
            start = edge
        } else {
            start = delta > 0 ? -1 : items.count
        }
        let nextIndex = min(max(0, start + delta), items.count - 1)
        let next = items[nextIndex]
        guard extending else {
            return SelectionCursor(selection: [next], anchor: next, lead: next)
        }
        let anchor = cursor.anchor ?? origin ?? next
        guard let anchorIndex = items.firstIndex(of: anchor) else {
            return SelectionCursor(selection: [next], anchor: next, lead: next)
        }
        let lower = min(anchorIndex, nextIndex)
        let upper = max(anchorIndex, nextIndex)
        return SelectionCursor(selection: Set(items[lower...upper]), anchor: anchor, lead: next)
    }

    private static func sole<ID: Hashable>(_ selection: Set<ID>, in items: [ID]) -> ID? {
        guard selection.count == 1, let only = selection.first, items.contains(only) else { return nil }
        return only
    }

    private static func edge<ID: Hashable>(_ selection: Set<ID>, in items: [ID], delta: Int) -> Int? {
        let indexes = selection.compactMap { items.firstIndex(of: $0) }
        guard !indexes.isEmpty else { return nil }
        return delta > 0 ? indexes.max() : indexes.min()
    }
}

struct KeyboardFocus {
    fileprivate var binding: FocusState<KeyboardTarget?>.Binding

    init(_ binding: FocusState<KeyboardTarget?>.Binding) {
        self.binding = binding
    }

    var target: KeyboardTarget? {
        get { binding.wrappedValue }
        nonmutating set { binding.wrappedValue = newValue }
    }

    /// まだどこもフォーカスしていないときだけ引き取る。一覧の再生成で奪い返さない。
    func claimIfIdle(_ target: KeyboardTarget) {
        guard self.target == nil else { return }
        self.target = target
    }
}

private struct KeyboardFocusKey: EnvironmentKey {
    static let defaultValue: KeyboardFocus? = nil
}

extension EnvironmentValues {
    var keyboardFocus: KeyboardFocus? {
        get { self[KeyboardFocusKey.self] }
        set { self[KeyboardFocusKey.self] = newValue }
    }
}

extension View {
    /// このビューを、指定した一覧のフォーカス対象にする。
    func keyboardTarget(_ target: KeyboardTarget, focusable: Bool = false) -> some View {
        modifier(KeyboardTargetModifier(target: target, focusable: focusable))
    }

    /// この一覧にフォーカスがあるあいだ、上下キーで選択を動かす。
    /// extending は Shift が押されているとき true。
    func selectionArrows(target: KeyboardTarget, move: @escaping (_ delta: Int, _ extending: Bool) -> Void) -> some View {
        modifier(SelectionArrowModifier(target: target, move: move))
    }

    /// シートは親ウィンドウのフォーカスを引き継がない。開いた一覧が上下キーを受け取る。
    func sheetKeyboardScope(_ initial: KeyboardTarget) -> some View {
        modifier(SheetKeyboardScope(initial: initial))
    }
}

private struct SheetKeyboardScope: ViewModifier {
    var initial: KeyboardTarget
    @FocusState private var keyboardTarget: KeyboardTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.keyboardFocus, KeyboardFocus($keyboardTarget))
            .defaultFocus($keyboardTarget, initial)
            .onAppear {
                DispatchQueue.main.async {
                    if keyboardTarget == nil {
                        keyboardTarget = initial
                    }
                }
            }
    }
}

private struct KeyboardTargetModifier: ViewModifier {
    var target: KeyboardTarget
    var focusable: Bool
    @Environment(\.keyboardFocus) private var keyboardFocus

    @ViewBuilder
    func body(content: Content) -> some View {
        if let keyboardFocus {
            if focusable {
                content
                    .focusable()
                    .focused(keyboardFocus.binding, equals: target)
                    .focusEffectDisabled()
            } else {
                content.focused(keyboardFocus.binding, equals: target)
            }
        } else {
            content
        }
    }
}

private struct SelectionArrowModifier: ViewModifier {
    var target: KeyboardTarget
    var move: (Int, Bool) -> Void
    @Environment(\.keyboardFocus) private var keyboardFocus

    func body(content: Content) -> some View {
        content
            .onKeyPress(phases: [.down, .repeat]) { press in
                let delta: Int
                switch press.key {
                case .upArrow: delta = -1
                case .downArrow: delta = 1
                default: return .ignored
                }
                // 修飾キー付きの上下は、Shift で範囲を伸ばすときだけ受け取る
                let modifiers = press.modifiers.subtracting(.capsLock)
                guard modifiers.isEmpty || modifiers == .shift else { return .ignored }
                return step(delta, extending: modifiers.contains(.shift))
            }
    }

    private func step(_ delta: Int, extending: Bool) -> KeyPress.Result {
        guard keyboardFocus?.target == target else { return .ignored }
        move(delta, extending)
        return .handled
    }
}
