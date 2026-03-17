import Cocoa

final class PanelView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel: NSTextField?
    let contentStack = NSStackView()

    init(title: String, subtitle: String? = nil) {
        if let subtitle {
            let label = NSTextField(labelWithString: subtitle)
            label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            self.subtitleLabel = label
        } else {
            self.subtitleLabel = nil
        }

        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 24
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.95, alpha: 1).cgColor

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .labelColor

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.addArrangedSubview(titleLabel)
        if let subtitleLabel {
            headerStack.addArrangedSubview(subtitleLabel)
        }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12

        let rootStack = NSStackView(views: [headerStack, contentStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MetricCardView: NSView {
    init(title: String, value: String, accentColor: NSColor) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = accentColor.withAlphaComponent(0.1).cgColor
        layer?.cornerRadius = 22
        layer?.borderWidth = 1
        layer?.borderColor = accentColor.withAlphaComponent(0.18).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        valueLabel.textColor = accentColor

        let marker = NSView()
        marker.wantsLayer = true
        marker.layer?.backgroundColor = accentColor.cgColor
        marker.layer?.cornerRadius = 4
        marker.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(marker)
        addSubview(stack)

        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            marker.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            marker.widthAnchor.constraint(equalToConstant: 28),
            marker.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: marker.bottomAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 112)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class TagView: NSView {
    init(title: String, tintColor: NSColor) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = tintColor.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        layer?.borderColor = tintColor.withAlphaComponent(0.2).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = tintColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PreviewCanvasView: NSView {
    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.22, alpha: 1).cgColor
        layer?.cornerRadius = 22

        let topStrip = makePane(identifier: "preview-top-strip", color: NSColor(calibratedRed: 0.15, green: 0.21, blue: 0.31, alpha: 1))
        let leftRail = makePane(identifier: "preview-left-rail", color: NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.28, alpha: 1))
        let summaryCard = makePane(identifier: "preview-summary-card", color: NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1))
        let chartCard = makePane(identifier: "preview-chart-card", color: NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1))

        addSubview(topStrip)
        addSubview(leftRail)
        addSubview(summaryCard)
        addSubview(chartCard)

        NSLayoutConstraint.activate([
            topStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            topStrip.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            topStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            topStrip.heightAnchor.constraint(equalToConstant: 48),
            leftRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            leftRail.topAnchor.constraint(equalTo: topStrip.bottomAnchor, constant: 14),
            leftRail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            leftRail.widthAnchor.constraint(equalToConstant: 146),
            summaryCard.leadingAnchor.constraint(equalTo: leftRail.trailingAnchor, constant: 14),
            summaryCard.topAnchor.constraint(equalTo: topStrip.bottomAnchor, constant: 14),
            summaryCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            summaryCard.heightAnchor.constraint(equalToConstant: 92),
            chartCard.leadingAnchor.constraint(equalTo: leftRail.trailingAnchor, constant: 14),
            chartCard.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 14),
            chartCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            chartCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])

        let titlePill = makePill(title: "OVERVIEW", tint: NSColor(calibratedRed: 0.52, green: 0.79, blue: 0.99, alpha: 1), identifier: "preview-pill-overview")
        let syncPill = makePill(title: "SYNCED", tint: NSColor(calibratedRed: 0.53, green: 0.88, blue: 0.7, alpha: 1), identifier: "preview-pill-synced")
        let topRow = NSStackView(views: [titlePill, syncPill])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topStrip.addSubview(topRow)
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor, constant: 14),
            topRow.centerYAnchor.constraint(equalTo: topStrip.centerYAnchor)
        ])

        let leftTitle = NSTextField(labelWithString: "Layers")
        leftTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        leftTitle.textColor = .white
        let leftSubtitle = NSTextField(labelWithString: "Toolbar\nInspector\nPreview\nStatus")
        leftSubtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        leftSubtitle.textColor = NSColor(calibratedWhite: 1, alpha: 0.72)
        leftSubtitle.maximumNumberOfLines = 4
        let leftStack = NSStackView(views: [leftTitle, leftSubtitle])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 10
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftRail.addSubview(leftStack)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: leftRail.leadingAnchor, constant: 14),
            leftStack.topAnchor.constraint(equalTo: leftRail.topAnchor, constant: 14)
        ])

        let metricsRow = NSStackView()
        metricsRow.orientation = .horizontal
        metricsRow.alignment = .top
        metricsRow.spacing = 12
        metricsRow.distribution = .fillEqually
        metricsRow.translatesAutoresizingMaskIntoConstraints = false
        metricsRow.addArrangedSubview(makeMiniCard(title: "Views", value: "148", identifier: "preview-mini-card-views"))
        metricsRow.addArrangedSubview(makeMiniCard(title: "Diffs", value: "08", identifier: "preview-mini-card-diffs"))
        summaryCard.addSubview(metricsRow)
        NSLayoutConstraint.activate([
            metricsRow.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 14),
            metricsRow.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 14),
            metricsRow.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -14),
            metricsRow.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: -14)
        ])

        let bars = NSStackView()
        bars.orientation = .horizontal
        bars.alignment = .bottom
        bars.spacing = 10
        bars.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<5 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 10
            bar.layer?.backgroundColor = (index % 2 == 0
                ? NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.88, alpha: 1)
                : NSColor(calibratedRed: 0.15, green: 0.69, blue: 0.54, alpha: 1)
            ).cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 34).isActive = true
            bar.heightAnchor.constraint(equalToConstant: CGFloat(44 + (index * 18))).isActive = true
            bar.identifier = NSUserInterfaceItemIdentifier("preview-chart-bar-\(index)")
            bar.setAccessibilityIdentifier("preview-chart-bar-\(index)")
            bars.addArrangedSubview(bar)
        }

        let footerPills = NSStackView(views: [
            makePill(title: "macOS", tint: NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.88, alpha: 1), identifier: "preview-pill-macos"),
            makePill(title: "Window", tint: NSColor(calibratedRed: 0.88, green: 0.54, blue: 0.18, alpha: 1), identifier: "preview-pill-window"),
            makePill(title: "Snapshot", tint: NSColor(calibratedRed: 0.15, green: 0.69, blue: 0.54, alpha: 1), identifier: "preview-pill-snapshot")
        ])
        footerPills.orientation = .horizontal
        footerPills.alignment = .centerY
        footerPills.spacing = 8
        footerPills.translatesAutoresizingMaskIntoConstraints = false

        chartCard.addSubview(bars)
        chartCard.addSubview(footerPills)
        NSLayoutConstraint.activate([
            bars.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 18),
            bars.topAnchor.constraint(equalTo: chartCard.topAnchor, constant: 18),
            footerPills.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 18),
            footerPills.topAnchor.constraint(equalTo: bars.bottomAnchor, constant: 18),
            footerPills.trailingAnchor.constraint(lessThanOrEqualTo: chartCard.trailingAnchor, constant: -18),
            footerPills.bottomAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: -18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makePane(identifier: String, color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = 18
        view.translatesAutoresizingMaskIntoConstraints = false
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    private func makeMiniCard(title: String, value: String, identifier: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.97, blue: 1, alpha: 1).cgColor
        view.layer?.cornerRadius = 14
        view.translatesAutoresizingMaskIntoConstraints = false
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = .labelColor

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])

        return view
    }

    private func makePill(title: String, tint: NSColor, identifier: String) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        pill.layer?.cornerRadius = 11
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.identifier = NSUserInterfaceItemIdentifier(identifier)
        pill.setAccessibilityIdentifier(identifier)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5)
        ])

        return pill
    }
}
