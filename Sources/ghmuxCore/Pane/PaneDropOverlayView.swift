import AppKit

extension NSPasteboard.PasteboardType {
    /// ペイン再配置ドラッグで paneId を運ぶ private 型。
    static let ghmuxPane = NSPasteboard.PasteboardType("com.ghmux.pane")
}

/// 各ペインに被せる透明なドロップ先ビュー。
///
/// 普段は `isHidden = true` でターミナルのマウス操作を一切阻害しない。
/// ドラッグ中だけ表示され、カーソル位置から 4 端ゾーン (左右上下) を判定し、
/// 着地先の半矩形をアクセントカラーで描く。ドロップ時に `onDrop(draggedId, edge)` を呼ぶ。
final class PaneDropOverlayView: NSView {

    /// cmux/bonsplit のドロップゾーンを ghmux 向けに 4 端へ縮約 (タブが無いため中央は無効)。
    enum Edge { case left, right, top, bottom, none }

    /// このオーバーレイが属するペインの ID。
    var paneId: String = ""
    /// ドロップ確定時に呼ぶ。戻り値が true なら移動成立。
    var onDrop: ((_ draggedId: String, _ edge: Edge) -> Bool)?

    private var currentEdge: Edge = .none {
        didSet { if currentEdge != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        registerForDraggedTypes([.ghmuxPane])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    // MARK: - ゾーン判定

    /// 端バンド = 各辺 25% (最小 80pt)。左右を上下より優先し、いずれにも入らなければ中央=none。
    private func edge(at point: NSPoint) -> Edge {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return .none }
        let bx = max(80, b.width * 0.25)
        let by = max(80, b.height * 0.25)
        if point.x < bx { return .left }
        if point.x > b.width - bx { return .right }
        if point.y < by { return .bottom } // 非 flipped: y 小 = 下
        if point.y > b.height - by { return .top }
        return .none
    }

    private func draggedId(from sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .ghmuxPane)
    }

    /// 自分自身のペインを掴んでいる場合は着地不可。
    private func resolveEdge(_ sender: NSDraggingInfo) -> Edge {
        guard let id = draggedId(from: sender), id != paneId else { return .none }
        return edge(at: convert(sender.draggingLocation, from: nil))
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        currentEdge = resolveEdge(sender)
        return currentEdge == .none ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        currentEdge = .none
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { currentEdge = .none }
        guard let id = draggedId(from: sender) else { return false }
        let edge = resolveEdge(sender)
        guard edge != .none else { return false }
        return onDrop?(id, edge) ?? false
    }

    // MARK: - 着地先インジケータ

    override func draw(_ dirtyRect: NSRect) {
        guard currentEdge != .none else { return }
        let b = bounds
        let rect: NSRect
        switch currentEdge {
        case .left:   rect = NSRect(x: 0, y: 0, width: b.width / 2, height: b.height)
        case .right:  rect = NSRect(x: b.width / 2, y: 0, width: b.width / 2, height: b.height)
        case .top:    rect = NSRect(x: 0, y: b.height / 2, width: b.width, height: b.height / 2)
        case .bottom: rect = NSRect(x: 0, y: 0, width: b.width, height: b.height / 2)
        case .none:   return
        }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

extension NSView {
    /// ドラッグ画像用に自身の見た目をビットマップ化する。
    func snapshotImage() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        guard let rep else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
