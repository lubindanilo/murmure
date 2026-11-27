import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Bandeau non activant, centré sur l'encoche et animé par Core Animation.
@MainActor
final class HUDController {
    private weak var controller: AppController?
    private var panel: NSPanel?
    private let root = CALayer()
    private let band = CAShapeLayer()
    private let reveal = CAShapeLayer()
    private let row = HUDRow()
    private var layout: Layout?
    private var visible = false
    private var hideWork: DispatchWorkItem?
    private var transition = 0
    private var phase: AppController.Phase = .idle
    private var start: Date?
    private var bag = Set<AnyCancellable>()

    private static let rowHeight: CGFloat = 38
    private static let ear: CGFloat = 6
    private static let margin: CGFloat = 24
    private static let closedOffset = rowHeight + 10

    private struct Layout: Equatable {
        let screen: CGRect
        let width: CGFloat
        let notchHeight: CGFloat
        let scale: CGFloat
    }

    init(controller: AppController) {
        self.controller = controller
        controller.$phase.removeDuplicates().sink { [weak self] phase in self?.phaseChanged(phase) }.store(in: &bag)
        controller.$recordingStart.sink { [weak self] start in self?.start = start }.store(in: &bag)
        controller.$level.sink { [weak self] level in self?.row.ribbon.setLevel(level) }.store(in: &bag)
        // Un mode autre que la dictée simple s'annonce dans le bandeau (« E-mail » au lieu de « J'écoute »).
        controller.$currentMode.removeDuplicates { $0?.id == $1?.id && $0?.name == $1?.name }
            .sink { [weak self] mode in self?.row.setMode(mode.flatMap { $0.isMain ? nil : $0.name }) }
            .store(in: &bag)
    }

    func prepare() {
        let panel = ensurePanel()
        place(panel)
        // Garder la fenêtre transparente entre deux dictées évite de devoir la réafficher
        // sur un tour de boucle AppKit avant que le serveur de rendu puisse l'animer.
        panel.orderFrontRegardless()
    }

    func show() {
        hideWork?.cancel()
        hideWork = nil
        let panel = ensurePanel()
        place(panel)
        guard !visible else { return }

        visible = true
        transition += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.display(phase, started: start)
        if Theme.reduceMotion {
            band.removeAnimation(forKey: "slide")
            reveal.removeAnimation(forKey: "slide")
            row.layer.removeAnimation(forKey: "appear")
            band.setAffineTransform(.identity)
            reveal.setAffineTransform(.identity)
            fade(to: 1, duration: 0.12)
        } else {
            root.removeAnimation(forKey: "fade")
            root.opacity = 1
            slide(to: 0, opening: true)
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.14
            appear.beginTime = row.layer.convertTime(CACurrentMediaTime(), from: nil) + 0.08
            appear.fillMode = .backwards
            row.layer.add(appear, forKey: "appear")
        }
        CATransaction.commit()

        if !panel.isVisible {
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
        }
        // Le premier rendu doit être soumis avant que l'appelant reprenne la main.
        CATransaction.flush()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func collapse() {
        guard visible else { return }
        visible = false
        transition += 1
        let closing = transition
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.transition == closing else { return }
                self.row.display(.idle, started: nil)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.root.opacity = 0
                let closed = CGAffineTransform(translationX: 0, y: Self.closedOffset)
                self.band.setAffineTransform(closed)
                self.reveal.setAffineTransform(closed)
                CATransaction.commit()
                self.controller?.resetIfFinished()
            }
        }
        if Theme.reduceMotion {
            fade(to: 0, duration: 0.12)
        } else {
            slide(to: Self.closedOffset, opening: false)
        }
        CATransaction.commit()
    }

    private func phaseChanged(_ phase: AppController.Phase) {
        self.phase = phase
        if visible { row.display(phase, started: start) }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let closed = CGAffineTransform(translationX: 0, y: Self.closedOffset)
        band.fillColor = NSColor.black.cgColor
        band.shadowColor = NSColor.black.cgColor
        band.shadowOpacity = 0.28
        band.shadowRadius = 10
        band.shadowOffset = CGSize(width: 0, height: -4)
        band.setAffineTransform(closed)
        reveal.setAffineTransform(closed)
        row.layer.mask = reveal
        root.addSublayer(band)
        root.addSublayer(row.layer)
        root.opacity = 0

        let container = NSView()
        container.layer = root
        container.wantsLayer = true
        panel.contentView = container
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let top = screen.safeAreaInsets.top
        let notchWidth: CGFloat
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        } else {
            notchWidth = 200
        }
        let next = Layout(screen: screen.frame, width: notchWidth, notchHeight: top, scale: screen.backingScaleFactor)
        guard next != layout else { return }
        layout = next

        let width = notchWidth + 2 * (Self.ear + Self.margin)
        let height = top + Self.rowHeight + Self.margin
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                              width: width, height: height), display: false)

        let shape = NotchShape(ear: Self.ear, radius: 14)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: notchWidth + 2 * Self.ear,
                                        height: top + Self.rowHeight)).cgPath
        // Le tracé SwiftUI part du haut. Le repère du calque part du bas.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: Self.margin, ty: height)
        let outline = path.copy(using: &flip)
        root.frame = bounds
        row.layer.frame = bounds
        for layer in [band, reveal] {
            // La position de base doit rester la même si l'écran change pendant la translation.
            layer.bounds = bounds
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            layer.path = outline
        }
        band.shadowPath = outline

        let inset: CGFloat = 12
        row.place(in: CGRect(x: Self.margin + Self.ear + inset, y: Self.margin,
                             width: notchWidth - 2 * inset, height: Self.rowHeight), scale: next.scale)
        CATransaction.commit()
    }

    private func slide(to y: CGFloat, opening: Bool) {
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.fromValue = band.presentation()?.affineTransform().ty ?? band.affineTransform().ty
        spring.toValue = y
        spring.stiffness = opening ? 420 : 520
        spring.damping = opening ? 26 : 46
        spring.duration = spring.settlingDuration
        for layer in [band, reveal] {
            layer.setAffineTransform(CGAffineTransform(translationX: 0, y: y))
            layer.add(spring, forKey: "slide")
        }
    }

    private func fade(to opacity: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = root.presentation()?.opacity ?? root.opacity
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.opacity = opacity
        root.add(animation, forKey: "fade")
    }
}

@MainActor
private final class HUDRow {
    let layer = CALayer()
    let ribbon = HUDRibbon()
    private let title = CATextLayer()
    private let elapsed = CATextLayer()
    private let symbol = CALayer()
    private let dots = (0..<3).map { _ in CALayer() }
    private var rect = CGRect.zero
    private var timer: Timer?
    private var titleInset: CGFloat = 0
    private var modeName: String?
    private var shown: AppController.Phase = .idle

    init() {
        title.truncationMode = .end
        elapsed.alignmentMode = .right
        symbol.contentsGravity = .resizeAspect
        for dot in dots {
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = 2.5
        }
        for sublayer in [ribbon.layer, symbol, title, elapsed] + dots {
            sublayer.isHidden = true
            layer.addSublayer(sublayer)
        }
    }

    func place(in rect: CGRect, scale: CGFloat) {
        self.rect = rect
        title.contentsScale = scale
        elapsed.contentsScale = scale
        symbol.contentsScale = scale
        ribbon.place(in: CGRect(x: rect.minX, y: rect.midY - HUDRibbon.height / 2,
                                width: HUDRibbon.width, height: HUDRibbon.height), backingScale: scale)
        symbol.frame = CGRect(x: rect.minX, y: rect.midY - 8, width: 16, height: 16)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: rect.minX + CGFloat(index) * 8, y: rect.midY - 2.5, width: 5, height: 5)
        }
        placeText()
    }

    /// Nom du mode en cours ; change le titre sur place pendant l'écoute, sans relancer le ruban.
    func setMode(_ name: String?) {
        guard name != modeName else { return }
        modeName = name
        guard case .recording = shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setTitle(name ?? "J'écoute")
        CATransaction.commit()
    }

    private func setTitle(_ label: String) {
        title.string = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        placeText()
    }

    func display(_ phase: AppController.Phase, started: Date?) {
        shown = phase
        timer?.invalidate()
        timer = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        title.isHidden = phase == .idle
        elapsed.isHidden = true
        ribbon.layer.isHidden = true
        symbol.isHidden = true
        for dot in dots {
            dot.isHidden = true
            dot.removeAnimation(forKey: "pulse")
        }
        titleInset = 0
        let label: String
        switch phase {
        case .recording:
            ribbon.layer.isHidden = false
            ribbon.start(reduceMotion: Theme.reduceMotion)
            titleInset = HUDRibbon.width + 8
            elapsed.isHidden = false
            updateElapsed(since: started)
            if let started {
                let nextTick = max(0, floor(Date().timeIntervalSince(started))) + 1
                let timer = Timer(fire: started.addingTimeInterval(nextTick), interval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateElapsed(since: started) }
                }
                timer.tolerance = 0.05
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            label = modeName ?? "J'écoute"
        case .transcribing:
            showDots()
            titleInset = 27
            label = "Mise au propre"
        case .polishing:
            showDots()
            titleInset = 27
            label = modeName.map { "\($0)…" } ?? "Mise au propre"
        case .translating:
            showSymbol("globe", color: .white)
            label = "Traduction"
        case .done(let message):
            showSymbol("checkmark.circle.fill", color: NSColor(srgbRed: 0.42, green: 0.84, blue: 0.57, alpha: 1),
                       filled: true)
            label = message
        case .failed(let message):
            showSymbol("exclamationmark.circle.fill", color: NSColor(srgbRed: 0.71, green: 0.73, blue: 1, alpha: 1),
                       filled: true)
            label = message
        case .idle:
            label = ""
        }
        if ribbon.layer.isHidden { ribbon.stop() }
        setTitle(label)
    }

    private func placeText() {
        let timeWidth = elapsed.isHidden ? 0 : (elapsed.string as? NSAttributedString)?.size().width.rounded(.up) ?? 0
        let timeGap: CGFloat = elapsed.isHidden ? 0 : 5
        let titleWidth = max(0, rect.width - titleInset - timeWidth - timeGap)
        let titleHeight = (title.string as? NSAttributedString)?.size().height.rounded(.up) ?? 0
        let timeHeight = (elapsed.string as? NSAttributedString)?.size().height.rounded(.up) ?? 0
        title.frame = CGRect(x: rect.minX + titleInset, y: (rect.midY - titleHeight / 2).rounded(),
                             width: titleWidth, height: titleHeight)
        elapsed.frame = CGRect(x: rect.maxX - timeWidth, y: (rect.midY - timeHeight / 2).rounded(),
                               width: timeWidth, height: timeHeight)
    }

    private func updateElapsed(since start: Date?) {
        let seconds = start.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        elapsed.string = NSAttributedString(string: String(format: "%d:%02d", seconds / 60, seconds % 60), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ])
        placeText()
        CATransaction.commit()
    }

    private func showSymbol(_ name: String, color: NSColor, filled: Bool = false) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(paletteColors: filled ? [.black, color] : [color]))
        symbol.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.isHidden = false
        titleInset = 24
    }

    private func showDots() {
        let reduceMotion = Theme.reduceMotion
        for (index, dot) in dots.enumerated() {
            dot.isHidden = false
            dot.opacity = 0.6
            guard !reduceMotion else { continue }
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.35, 1, 0.35, 0.35]
            pulse.duration = 0.9
            pulse.repeatCount = .infinity
            pulse.timeOffset = Double(2 - index) * 0.13
            dot.add(pulse, forKey: "pulse")
        }
    }
}

/// Silhouette d'encoche de MacBook : haut droit, bas arrondi, et raccords incurvés (« oreilles »)
/// qui la fondent dans le bord de l'écran.
struct NotchShape: Shape {
    static let defaultEar: CGFloat = 4
    var ear: CGFloat = NotchShape.defaultEar
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(radius, (w - 2 * ear) / 2, h)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - ear, y: ear), control: CGPoint(x: w - ear, y: 0))
        p.addLine(to: CGPoint(x: w - ear, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - ear - r, y: h), control: CGPoint(x: w - ear, y: h))
        p.addLine(to: CGPoint(x: ear + r, y: h))
        p.addQuadCurve(to: CGPoint(x: ear, y: h - r), control: CGPoint(x: ear, y: h))
        p.addLine(to: CGPoint(x: ear, y: ear))
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: ear, y: 0))
        p.closeSubpath()
        return p
    }
}
