import AppKit

extension NSPasteboard.PasteboardType {
    /// ワークスペース行の並べ替えドラッグで元インデックスを運ぶ private 型。
    static let ghmuxWorkspaceRow = NSPasteboard.PasteboardType("com.ghmux.workspace-row")
}

/// 画面左下に常駐するワークスペース一覧。
///
/// 1 行 = 1 ワークスペース (独立したペイン分割ツリー)。行クリックで切替、「+」で追加、
/// 各行の × で閉じる。ダブルクリックで名前を変更、行をドラッグして並べ替えできる。
/// 表示・操作は `RootViewController` へコールバックで委譲し、状態 (配列/選択) は
/// RootViewController が所有する。背景は常にダークなので `darkAqua` を固定する。
final class WorkspacesSidebarViewController: NSViewController {

    /// スクロール領域の documentView 兼ドロップ先。左上原点で行の並べ替えを扱う。
    private let listView = WorkspaceListView()

    private let titleLabel = NSTextField(labelWithString: "Workspaces")
    private let addButton = NSButton()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()

    /// 「+」ボタン。新規ワークスペースを要求する。
    var onAdd: (() -> Void)?
    /// 行クリック。指定インデックスのワークスペースへ切替を要求する。
    var onSelect: ((Int) -> Void)?
    /// 行の × 。指定インデックスのワークスペースのクローズを要求する。
    var onClose: ((Int) -> Void)?
    /// ドラッグ並べ替え。from を to の位置へ移動する要求。
    var onReorder: ((_ from: Int, _ to: Int) -> Void)?
    /// ダブルクリックでの改名。空文字なら既定名に戻す。
    var onRename: ((_ index: Int, _ name: String) -> Void)?

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        view = root

        configureHeader()
        configureList()

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -6),

            addButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 18),
            addButton.heightAnchor.constraint(equalToConstant: 18),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func configureHeader() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New workspace")
        addButton.imageScaling = .scaleProportionallyDown
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.contentTintColor = NSColor.secondaryLabelColor
        addButton.toolTip = "New workspace (⌘N)"
        addButton.target = self
        addButton.action = #selector(didTapAdd)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(addButton)
    }

    private func configureList() {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.onReorder = { [weak self] from, to in self?.onReorder?(from, to) }
        listView.addSubview(listStack)
        scrollView.documentView = listView
        view.addSubview(scrollView)

        // IssuesSidebar と同じ実績パターン: documentView を clip の leading/trailing/top に
        // 固定して幅を確定し、stack が高さを決める (bottom は固定しない)。横スクロールも防ぐ。
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            listStack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 6),
            listStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 6),
            listStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -6),
            listStack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -6),
        ])
    }

    @objc private func didTapAdd(_ sender: Any?) { onAdd?() }

    // MARK: - 折りたたみ

    /// 左カラム折りたたみ時に内容を隠す (タイトル/一覧)。
    func setContentHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
        scrollView.isHidden = hidden
    }

    // MARK: - 描画

    /// 一覧を再構築する。`titles` の順が表示順、`selectedIndex` が選択行。
    func reload(titles: [String], selectedIndex: Int) {
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let canClose = titles.count > 1
        var rows: [WorkspaceRowView] = []
        for (index, title) in titles.enumerated() {
            let row = WorkspaceRowView(index: index, title: title, selected: index == selectedIndex)
            row.canClose = canClose
            row.onClick = { [weak self] i in self?.onSelect?(i) }
            row.onClose = { [weak self] i in self?.onClose?(i) }
            row.onRename = { [weak self] i, name in self?.onRename?(i, name) }
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
            rows.append(row)
        }
        listView.rows = rows
    }
}

// MARK: - 行

/// 1 ワークスペースを表す行。左に名前、右に × 。
/// シングルクリックで選択、ダブルクリックで改名、ドラッグで並べ替えを開始する。
///
/// 注意: 選択は `mouseUp` で行う。`mouseDown` で即選択すると一覧が再構築され自分自身の
/// ビューが破棄されてしまい、以降の `mouseDragged` が届かず並べ替えが始まらないため。
private final class WorkspaceRowView: NSView, NSDraggingSource, NSTextFieldDelegate {

    let index: Int
    var canClose = true { didSet { closeButton.isHidden = !canClose } }
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onRename: ((Int, String) -> Void)?

    private let nameField = NSTextField()
    private let closeButton = NSButton()
    private let selected: Bool

    private var mouseDownPoint: NSPoint = .zero
    private var didStartDrag = false
    private var isEditing = false

    init(index: Int, title: String, selected: Bool) {
        self.index = index
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = (selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.30)
            : NSColor.clear).cgColor

        // 通常はラベル表示、ダブルクリック時のみ編集可能にする。
        nameField.stringValue = title
        nameField.font = NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        nameField.textColor = selected ? NSColor.labelColor : NSColor.secondaryLabelColor
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.lineBreakMode = .byTruncatingTail
        nameField.usesSingleLineMode = true
        nameField.maximumNumberOfLines = 1
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close workspace")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = NSColor.tertiaryLabelColor
        closeButton.toolTip = "Close workspace (⌘⇧W)"
        closeButton.target = self
        closeButton.action = #selector(didTapClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameField)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        closeButton.isHidden = !canClose
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(index:title:selected:)") }

    @objc private func didTapClose(_ sender: Any?) { onClose?(index) }

    // MARK: - クリック / ダブルクリック / ドラッグ

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        mouseDownPoint = event.locationInWindow
        if event.clickCount >= 2 {
            beginRename()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, !isEditing else { return }
        let dx = event.locationInWindow.x - mouseDownPoint.x
        let dy = event.locationInWindow.y - mouseDownPoint.y
        guard (dx * dx + dy * dy) > 9 else { return } // 約 3pt のしきい値
        didStartDrag = true
        let item = NSPasteboardItem()
        item.setString("\(index)", forType: .ghmuxWorkspaceRow)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard !didStartDrag, !isEditing, event.clickCount == 1 else { return }
        onClick?(index)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    // MARK: - 改名 (インライン編集)

    private func beginRename() {
        isEditing = true
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = true
        nameField.drawsBackground = true
        nameField.backgroundColor = NSColor.textBackgroundColor
        nameField.textColor = NSColor.textColor
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    private func endRename(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.textColor = selected ? NSColor.labelColor : NSColor.secondaryLabelColor
        if commit { onRename?(index, nameField.stringValue) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Enter / フォーカス喪失で確定 (Esc の取消は下の doCommandBy で扱う)。
        endRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }
}

// MARK: - リスト (ドロップ先 + 並べ替え)

/// 行スタックを載せる flipped な documentView 兼ドロップ先。
/// ドラッグ中はカーソル y から挿入位置を求めてインジケータを描き、ドロップで並べ替えを通知する。
private final class WorkspaceListView: NSView {

    var rows: [WorkspaceRowView] = []
    var onReorder: ((_ from: Int, _ to: Int) -> Void)?

    /// 挿入予定位置 (0...rows.count)。-1 は非表示。
    private var insertionIndex: Int = -1 {
        didSet { if insertionIndex != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.ghmuxWorkspaceRow])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isFlipped: Bool { true }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertionIndex = -1 }

    private func sourceIndex(_ sender: NSDraggingInfo) -> Int? {
        sender.draggingPasteboard.string(forType: .ghmuxWorkspaceRow).flatMap(Int.init)
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sourceIndex(sender) != nil else { insertionIndex = -1; return [] }
        insertionIndex = insertionPoint(at: convert(sender.draggingLocation, from: nil))
        return .move
    }

    /// 行の矩形を自ビュー座標へ変換した midY (行は listStack 配下なので座標変換が必要)。
    private func rowMidY(_ row: NSView) -> CGFloat {
        convert(row.bounds, from: row).midY
    }

    /// カーソル y から「行と行の間」の挿入インデックスを求める。
    /// 各行の縦中点より上なら手前、末尾行の中点より下なら末尾に挿入する。
    private func insertionPoint(at point: NSPoint) -> Int {
        for (i, row) in rows.enumerated() where point.y < rowMidY(row) {
            return i
        }
        return rows.count
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { insertionIndex = -1 }
        guard let from = sourceIndex(sender) else { return false }
        var to = insertionPoint(at: convert(sender.draggingLocation, from: nil))
        // 自分より後ろへ挿入する場合、自分を抜いた分だけ 1 つ手前になる。
        if to > from { to -= 1 }
        guard to != from, to >= 0, to < rows.count else { return false }
        onReorder?(from, to)
        return true
    }

    // MARK: - 挿入インジケータ

    override func draw(_ dirtyRect: NSRect) {
        guard insertionIndex >= 0, !rows.isEmpty else { return }
        let y: CGFloat
        if insertionIndex < rows.count {
            y = convert(rows[insertionIndex].bounds, from: rows[insertionIndex]).minY - 1
        } else if let last = rows.last {
            y = convert(last.bounds, from: last).maxY + 1
        } else {
            return
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 6, y: y))
        path.line(to: NSPoint(x: bounds.width - 6, y: y))
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
