import AppKit

/// 比率ベースの 2 分割ビュー。Ghostty の SwiftUI `SplitView` を AppKit に移植したもの。
///
/// `NSSplitView` のネストは内部制約が壊れやすく非対称レイアウトで破綻するため、
/// レイアウトを完全に自前管理する。`ratio` (0..1) で first/second のサイズを決め、
/// 中央のディバイダをドラッグして `ratio` を更新する。
final class BinarySplitView: NSView {

    enum Direction {
        case horizontal // 左右 (first = 左, second = 右)
        case vertical   // 上下 (first = 上, second = 下)
    }

    let direction: Direction
    var ratio: CGFloat {
        didSet { needsLayout = true }
    }
    /// ドラッグでディバイダが動いたとき、新しい比率を通知する (ツリーへ永続化する用)。
    var onRatioChange: ((CGFloat) -> Void)?

    private let first: NSView
    private let second: NSView
    private let divider = DividerView()

    private let visibleThickness: CGFloat = 1
    private let hitThickness: CGFloat = 8
    private let minSize: CGFloat = 60

    init(direction: Direction, ratio: CGFloat, first: NSView, second: NSView) {
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
        super.init(frame: .zero)

        for child in [first, second] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        divider.direction = direction
        divider.onDrag = { [weak self] pointInSelf in
            self?.handleDrag(to: pointInSelf)
        }
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // 左上原点で計算しやすくする

    override func layout() {
        super.layout()
        let b = bounds
        let v = visibleThickness
        switch direction {
        case .horizontal:
            let split = (b.width * ratio).rounded()
            first.frame = NSRect(x: 0, y: 0, width: max(0, split - v / 2), height: b.height)
            second.frame = NSRect(x: split + v / 2, y: 0, width: max(0, b.width - split - v / 2), height: b.height)
            divider.frame = NSRect(x: split - hitThickness / 2, y: 0, width: hitThickness, height: b.height)
        case .vertical:
            let split = (b.height * ratio).rounded()
            first.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, split - v / 2))
            second.frame = NSRect(x: 0, y: split + v / 2, width: b.width, height: max(0, b.height - split - v / 2))
            divider.frame = NSRect(x: 0, y: split - hitThickness / 2, width: b.width, height: hitThickness)
        }
    }

    private func handleDrag(to point: NSPoint) {
        let b = bounds
        let newRatio: CGFloat
        switch direction {
        case .horizontal:
            let x = min(max(minSize, point.x), b.width - minSize)
            newRatio = b.width > 0 ? x / b.width : 0.5
        case .vertical:
            let y = min(max(minSize, point.y), b.height - minSize)
            newRatio = b.height > 0 ? y / b.height : 0.5
        }
        ratio = newRatio
        onRatioChange?(newRatio)
    }
}

/// ドラッグ可能なディバイダ。ドラッグ位置 (親座標) をコールバックで通知する。
private final class DividerView: NSView {
    var direction: BinarySplitView.Direction = .horizontal
    var onDrag: ((NSPoint) -> Void)?

    override func resetCursorRects() {
        let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        // ドラッグ開始を受理する (何もしない)。
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        let p = parent.convert(event.locationInWindow, from: nil)
        onDrag?(p)
    }
}
