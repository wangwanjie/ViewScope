import AppKit
import SnapKit
import ViewScopeServer

/// 预览工具栏里的“布局诊断”弹窗：按种类统计、问题列表，点击条目选中对应节点。
@MainActor
final class LayoutDiagnosticsPopoverController: NSViewController {
    private let report: LayoutDiagnosticsReport
    private let nodeTitleProvider: (String) -> String
    private let onSelectIssue: (LayoutDiagnosticIssue) -> Void
    private let onShowsOverlayChange: (Bool) -> Void
    private let showsOverlay: Bool

    private let summaryLabel = NSTextField(labelWithString: "")
    private let overlayToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let kindPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// 弹窗里 popUp 的种类顺序；第 0 项为“全部”。
    private var kindOptions: [LayoutDiagnosticIssue.Kind?] = []
    private var visibleIssues: [LayoutDiagnosticIssue] = []

    init(
        report: LayoutDiagnosticsReport,
        showsOverlay: Bool,
        nodeTitleProvider: @escaping (String) -> String,
        onSelectIssue: @escaping (LayoutDiagnosticIssue) -> Void,
        onShowsOverlayChange: @escaping (Bool) -> Void
    ) {
        self.report = report
        self.showsOverlay = showsOverlay
        self.nodeTitleProvider = nodeTitleProvider
        self.onSelectIssue = onSelectIssue
        self.onShowsOverlayChange = onShowsOverlayChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        view = container

        let titleLabel = NSTextField(labelWithString: L10n.previewToolsDiagnosticsTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.stringValue = L10n.previewToolsDiagnosticsSummary(
            errors: report.countsBySeverity[.error] ?? 0,
            warnings: report.countsBySeverity[.warning] ?? 0,
            infos: report.countsBySeverity[.info] ?? 0
        )

        overlayToggle.title = L10n.previewToolsDiagnosticsShowOverlay
        overlayToggle.state = showsOverlay ? .on : .off
        overlayToggle.target = self
        overlayToggle.action = #selector(handleOverlayToggle(_:))
        overlayToggle.font = NSFont.systemFont(ofSize: 11)

        configureKindPopUp()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DiagnosticsColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleTableClick(_:))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel.stringValue = L10n.previewToolsDiagnosticsEmpty
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        [titleLabel, summaryLabel, overlayToggle, kindPopUpButton, scrollView, emptyLabel].forEach {
            container.addSubview($0)
        }
        titleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(12)
        }
        summaryLabel.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.leading.equalTo(titleLabel.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualToSuperview().inset(12)
        }
        overlayToggle.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.equalToSuperview().inset(12)
        }
        kindPopUpButton.snp.makeConstraints { make in
            make.centerY.equalTo(overlayToggle)
            make.trailing.equalToSuperview().inset(12)
            make.leading.greaterThanOrEqualTo(overlayToggle.snp.trailing).offset(8)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(overlayToggle.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview().inset(8)
        }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        reloadIssues()
        preferredContentSize = NSSize(width: 460, height: 380)
    }

    private func configureKindPopUp() {
        kindPopUpButton.removeAllItems()
        kindOptions = [nil]
        kindPopUpButton.addItem(withTitle: "\(L10n.previewToolsDiagnosticsAllKinds) (\(report.allIssues.count))")
        for kind in LayoutDiagnosticIssue.Kind.allCases {
            let count = report.countsByKind[kind] ?? 0
            guard count > 0 else {
                continue
            }
            kindOptions.append(kind)
            kindPopUpButton.addItem(withTitle: "\(kind.title) (\(count))")
        }
        kindPopUpButton.target = self
        kindPopUpButton.action = #selector(handleKindChange(_:))
        kindPopUpButton.font = NSFont.systemFont(ofSize: 11)
        kindPopUpButton.controlSize = .small
    }

    private func reloadIssues() {
        let selectedIndex = max(kindPopUpButton.indexOfSelectedItem, 0)
        let selectedKind = selectedIndex < kindOptions.count ? kindOptions[selectedIndex] : nil
        visibleIssues = report.allIssues.filter { issue in
            guard let selectedKind else {
                return true
            }
            return issue.kind == selectedKind
        }
        tableView.reloadData()
        emptyLabel.isHidden = visibleIssues.isEmpty == false
    }

    @objc private func handleKindChange(_ sender: Any?) {
        reloadIssues()
    }

    @objc private func handleOverlayToggle(_ sender: NSButton) {
        onShowsOverlayChange(sender.state == .on)
    }

    @objc private func handleTableClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < visibleIssues.count else {
            return
        }
        onSelectIssue(visibleIssues[row])
    }
}

extension LayoutDiagnosticsPopoverController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleIssues.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DiagnosticsIssueCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LayoutDiagnosticsIssueCellView
            ?? LayoutDiagnosticsIssueCellView(frame: .zero)
        cell.identifier = identifier
        let issue = visibleIssues[row]
        cell.configure(issue: issue, nodeTitle: nodeTitleProvider(issue.nodeID))
        return cell
    }
}

/// 诊断列表的一行：严重程度图标 + 节点名 + 问题说明。
private final class LayoutDiagnosticsIssueCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(messageLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(4)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualToSuperview().inset(4)
            make.top.equalToSuperview().offset(2)
        }
        messageLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.trailing.lessThanOrEqualToSuperview().inset(4)
            make.top.equalTo(titleLabel.snp.bottom).offset(1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(issue: LayoutDiagnosticIssue, nodeTitle: String) {
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = issue.severity.color
        titleLabel.stringValue = "\(nodeTitle) · \(issue.kind.title)"
        messageLabel.stringValue = issue.message
        toolTip = issue.message
    }
}
