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
    func selectionArrows(target: KeyboardTarget, move: @escaping (Int) -> Void) -> some View {
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
    var move: (Int) -> Void
    @Environment(\.keyboardFocus) private var keyboardFocus

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { _ in
                step(-1)
            }
            .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { _ in
                step(1)
            }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard keyboardFocus?.target == target else { return .ignored }
        move(delta)
        return .handled
    }
}
