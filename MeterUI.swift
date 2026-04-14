import Cocoa

enum MeterState {
    case loading
    case loaded(usedPercent: Int, resetText: String, iconColor: NSColor)
    case error(String)
}

final class MeterBarView: NSView {
    var barWidth: CGFloat = 82 {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var progress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var percentText: String = "--" {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: barWidth, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 1.0, alpha: 0.08).setFill()
        bgPath.fill()

        let clamped = max(0.0, min(1.0, progress))
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * clamped, height: rect.height)
        if fillRect.width > 0 {
            NSGraphicsContext.saveGraphicsState()
            bgPath.addClip()
            let fillGradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.98, alpha: 1.0),
                NSColor(calibratedRed: 0.03, green: 0.44, blue: 0.90, alpha: 1.0)
            ])
            fillGradient?.draw(in: fillRect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 0.98),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: percentText, attributes: attrs)
        attributed.draw(
            with: NSRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: rect.height + 2),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }
}

final class PassThroughStatusView: NSView {
    var onSizeChange: (() -> Void)?
    var loadingIconColor: NSColor = .systemOrange

    var state: MeterState = .loading {
        didSet {
            applyState()
        }
    }

    private let labelText: String?
    private let icon: NSImage?
    private let labelField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let meterView = MeterBarView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()

    override var intrinsicContentSize: NSSize {
        let size = stackView.fittingSize
        return NSSize(width: ceil(size.width), height: 22)
    }

    init(icon: NSImage?, labelText: String? = nil) {
        self.labelText = labelText
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 166, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        configureSubviews()
        applyState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func configureSubviews() {
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = NSFont.systemFont(ofSize: 10, weight: .black)
        labelField.textColor = NSColor(calibratedWhite: 0.90, alpha: 0.95)
        labelField.alignment = .center
        labelField.stringValue = labelText ?? ""
        labelField.isHidden = (labelText == nil)
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15)
        ])

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.setContentHuggingPriority(.required, for: .horizontal)
        meterView.setContentCompressionResistancePriority(.required, for: .horizontal)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 0.95)
        timeLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        timeLabel.alignment = .left
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 3
        stackView.addArrangedSubview(labelField)
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(meterView)
        stackView.addArrangedSubview(timeLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyState() {
        switch state {
        case .loading:
            iconView.image = tintedImage(color: loadingIconColor)
            meterView.progress = 0.18
            meterView.percentText = "--"
            timeLabel.stringValue = "sync"
            timeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 0.95)
        case .loaded(let usedPercent, let resetText, let iconColor):
            iconView.image = tintedImage(color: iconColor)
            meterView.progress = CGFloat(usedPercent) / 100.0
            meterView.percentText = "\(usedPercent)%"
            timeLabel.stringValue = resetText
            timeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 0.95)
        case .error:
            iconView.image = tintedImage(color: NSColor(calibratedWhite: 0.62, alpha: 0.95))
            meterView.progress = 0.0
            meterView.percentText = "--"
            timeLabel.stringValue = "err"
            timeLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 0.95)
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onSizeChange?()
    }

    private func tintedImage(color: NSColor) -> NSImage? {
        guard let icon else { return nil }
        let image = icon.copy() as? NSImage ?? icon
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    func snapshotImage() -> NSImage? {
        let size = intrinsicContentSize
        let frame = NSRect(origin: .zero, size: size)
        self.frame = frame
        layoutSubtreeIfNeeded()

        guard let rep = bitmapImageRepForCachingDisplay(in: frame) else {
            return nil
        }
        cacheDisplay(in: frame, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}

final class CompactProviderStatusView: NSView {
    var onSizeChange: (() -> Void)?
    var loadingIconColor: NSColor = .systemOrange

    var state: MeterState = .loading {
        didSet {
            applyState()
        }
    }

    private let icon: NSImage?
    private let iconView = NSImageView()
    private let meterView = MeterBarView()
    private let stackView = NSStackView()

    override var intrinsicContentSize: NSSize {
        let size = stackView.fittingSize
        return NSSize(width: ceil(size.width), height: 22)
    }

    init(icon: NSImage?) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 74, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        configureSubviews()
        applyState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14)
        ])

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.barWidth = 48
        meterView.setContentHuggingPriority(.required, for: .horizontal)
        meterView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(meterView)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyState() {
        switch state {
        case .loading:
            iconView.image = tintedImage(color: loadingIconColor)
            meterView.progress = 0.18
            meterView.percentText = "--"
        case .loaded(let usedPercent, _, let iconColor):
            iconView.image = tintedImage(color: iconColor)
            meterView.progress = CGFloat(usedPercent) / 100.0
            meterView.percentText = "\(usedPercent)%"
        case .error:
            iconView.image = tintedImage(color: NSColor(calibratedWhite: 0.62, alpha: 0.95))
            meterView.progress = 0.0
            meterView.percentText = "--"
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onSizeChange?()
    }

    private func tintedImage(color: NSColor) -> NSImage? {
        guard let icon else { return nil }
        let image = icon.copy() as? NSImage ?? icon
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}

final class CombinedStatusItemView: NSView {
    var onSizeChange: (() -> Void)?

    var claudeState: MeterState = .loading {
        didSet {
            claudeView.state = claudeState
            onSizeChange?()
        }
    }

    var codexState: MeterState = .loading {
        didSet {
            codexView.state = codexState
            onSizeChange?()
        }
    }

    var cursorState: MeterState = .loading {
        didSet {
            cursorView.state = cursorState
            onSizeChange?()
        }
    }

    var claudeVisible: Bool = true {
        didSet {
            guard claudeVisible != oldValue else { return }
            updateVisibility()
        }
    }

    var codexVisible: Bool = true {
        didSet {
            guard codexVisible != oldValue else { return }
            updateVisibility()
        }
    }

    var cursorVisible: Bool = true {
        didSet {
            guard cursorVisible != oldValue else { return }
            updateVisibility()
        }
    }

    var hasVisibleProviders: Bool {
        claudeVisible || codexVisible || cursorVisible
    }

    private let claudeView: CompactProviderStatusView
    private let codexView: CompactProviderStatusView
    private let cursorView: CompactProviderStatusView
    private let stackView = NSStackView()

    override var intrinsicContentSize: NSSize {
        let size = stackView.fittingSize
        return NSSize(width: ceil(size.width), height: 22)
    }

    init(claudeIcon: NSImage?, codexIcon: NSImage?, cursorIcon: NSImage?) {
        self.claudeView = CompactProviderStatusView(icon: claudeIcon)
        self.codexView = CompactProviderStatusView(icon: codexIcon)
        self.cursorView = CompactProviderStatusView(icon: cursorIcon)
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        codexView.loadingIconColor = NSColor(calibratedWhite: 0.96, alpha: 0.98)
        cursorView.loadingIconColor = NSColor(calibratedWhite: 0.96, alpha: 0.98)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func configureSubviews() {
        claudeView.translatesAutoresizingMaskIntoConstraints = false
        codexView.translatesAutoresizingMaskIntoConstraints = false
        cursorView.translatesAutoresizingMaskIntoConstraints = false
        claudeView.onSizeChange = { [weak self] in self?.onSizeChange?() }
        codexView.onSizeChange = { [weak self] in self?.onSizeChange?() }
        cursorView.onSizeChange = { [weak self] in self?.onSizeChange?() }

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.addArrangedSubview(claudeView)
        stackView.addArrangedSubview(codexView)
        stackView.addArrangedSubview(cursorView)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateVisibility()
    }

    private func updateVisibility() {
        claudeView.isHidden = !claudeVisible
        codexView.isHidden = !codexVisible
        cursorView.isHidden = !cursorVisible
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onSizeChange?()
    }

    func snapshotImage() -> NSImage? {
        guard hasVisibleProviders else {
            return nil
        }
        let size = intrinsicContentSize
        let frame = NSRect(origin: .zero, size: size)
        self.frame = frame
        layoutSubtreeIfNeeded()

        guard let rep = bitmapImageRepForCachingDisplay(in: frame) else {
            return nil
        }
        cacheDisplay(in: frame, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
