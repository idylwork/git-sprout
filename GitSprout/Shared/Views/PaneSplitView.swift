import AppKit
import SwiftUI

/// 先頭ペインの寸法を保持する分割。中身が変わっても、ドラッグした幅や高さは動かさない。
struct PaneSplit<Primary: View, Secondary: View>: View {
    var axis: Axis
    @Binding var primarySize: CGFloat
    var minPrimary: CGFloat
    var maxPrimary: CGFloat = .infinity
    var minSecondary: CGFloat
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    /// 見た目の隙間。掴む範囲はこの両側にはみ出す。
    private let gap: CGFloat = 1
    private let hit: CGFloat = 9
    private var overlap: CGFloat { (hit - gap) / 2 }
    private var horizontal: Bool { axis == .horizontal }

    var body: some View {
        GeometryReader { proxy in
            let total = horizontal ? proxy.size.width : proxy.size.height
            let size = fitted(primarySize, total: total)
            arranged(size: size, total: total)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func arranged(size: CGFloat, total: CGFloat) -> some View {
        let grip = SplitGrip(resizesWidth: horizontal, thickness: hit, currentSize: size) { proposed in
            primarySize = fitted(proposed, total: total)
        }
        if horizontal {
            HStack(spacing: -overlap) {
                primary()
                    .frame(width: size)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                grip
                    .frame(width: hit)
                    .frame(maxHeight: .infinity)
                    .zIndex(1)
                secondary()
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: -overlap) {
                primary()
                    .frame(height: size)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                grip
                    .frame(height: hit)
                    .frame(maxWidth: .infinity)
                    .zIndex(1)
                secondary()
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
    }

    private func fitted(_ preferred: CGFloat, total: CGFloat) -> CGFloat {
        let available = total - gap
        guard available > 1 else { return max(preferred, 0) }
        let upper = min(maxPrimary, available - minSecondary)
        if upper < minPrimary {
            let share = available * (minPrimary / max(minPrimary + minSecondary, 1))
            return min(max(share, 0), available)
        }
        return min(max(preferred, minPrimary), upper)
    }
}

/// 分割の境目。ウィンドウ座標で追うので、ドラッグ中に自分の位置が動いても幅が追従する。
private struct SplitGrip: NSViewRepresentable {
    var resizesWidth: Bool
    var thickness: CGFloat
    var currentSize: CGFloat
    var onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.resizesWidth = resizesWidth
        view.currentSize = currentSize
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.resizesWidth = resizesWidth
        view.currentSize = currentSize
        view.onResize = onResize
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GripView, context: Context) -> CGSize? {
        if resizesWidth {
            CGSize(width: thickness, height: proposal.height ?? thickness)
        } else {
            CGSize(width: proposal.width ?? thickness, height: thickness)
        }
    }
}

private final class GripView: NSView {
    var resizesWidth = true
    var currentSize: CGFloat = 0
    var onResize: ((CGFloat) -> Void)?

    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizesWidth ? .resizeLeftRight : .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        if resizesWidth {
            NSRect(x: floor((bounds.width - 1) / 2), y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: floor((bounds.height - 1) / 2), width: bounds.width, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let start = axisPosition(of: event)
        let origin = currentSize
        let cursor = resizesWidth ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
        cursor.set()
        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.window?.invalidateCursorRects(for: self)
                return
            }
            cursor.set()
            let delta = self.resizesWidth
                ? self.axisPosition(of: event) - start
                : start - self.axisPosition(of: event)
            self.onResize?(origin + delta)
        }
    }

    private func axisPosition(of event: NSEvent) -> CGFloat {
        resizesWidth ? event.locationInWindow.x : event.locationInWindow.y
    }
}
