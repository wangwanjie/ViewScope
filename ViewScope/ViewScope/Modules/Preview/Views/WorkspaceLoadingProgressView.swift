import AppKit

final class WorkspaceLoadingProgressView: NSView {
    @objc private dynamic var progress: CGFloat = 0 {
        didSet {
            fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        }
    }

    private let fillLayer = CALayer()
    private var animationTimer: Timer?
    private var isAnimatingProgress = false
    private var isFinishing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(fillLayer)
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityIdentifier("workspace.loadingProgress")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }

    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? {
        guard key == "progress" else {
            return super.animation(forKey: key)
        }

        let animation = CABasicAnimation()
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    func startAnimating() {
        guard isAnimatingProgress == false else { return }
        isAnimatingProgress = true
        isFinishing = false
        animationTimer?.invalidate()
        isHidden = false
        alphaValue = 1
        progress = max(progress, 0.08)

        let timer = Timer(
            timeInterval: 0.12,
            target: self,
            selector: #selector(handleAnimationTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func finishAnimatingIfNeeded() {
        guard isHidden == false, isFinishing == false else { return }
        isAnimatingProgress = false
        isFinishing = true
        animationTimer?.invalidate()
        animationTimer = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            self.animator().progress = 1
        } completionHandler: {
            Task { @MainActor in
                self.isFinishing = false
                self.stopImmediately()
            }
        }
    }

    func stopImmediately() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimatingProgress = false
        isFinishing = false
        progress = 0
        alphaValue = 0
        isHidden = true
        alphaValue = 1
    }

    @objc private func handleAnimationTick(_ timer: Timer) {
        let nextStep: CGFloat = progress < 0.56 ? 0.08 : 0.025
        progress = min(0.72, progress + nextStep)
        if progress >= 0.72 {
            timer.invalidate()
            animationTimer = nil
        }
    }
}

