import AppKit
import SwiftUI

/// Carte affichée quand la dictée se termine sans champ de texte actif : le texte est copié,
/// et la carte se glisse dans n'importe quel champ. Elle part après un dépôt, Échap, la dictée suivante,
/// ou une minute sans être survolée.
@MainActor
final class DropCardController {
    static let shared = DropCardController()

    private var panel: NSPanel?
    private var expiry: DispatchWorkItem?
    private var hovering = false

    private static let width: CGFloat = 360
    private static let lifetime: TimeInterval = 60

    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: DropCard(text: text,
                                                    close: { [weak self] in self?.dismiss() },
                                                    hover: { [weak self] in self?.hover($0) }))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !Theme.reduceMotion {
            panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 8))
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.reduceMotion ? 0.12 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        scheduleExpiry()
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                guard panel.alphaValue == 0 else { return }
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { expiry?.cancel() } else { scheduleExpiry() }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard !hovering else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

private struct DropCard: View {
    let text: String
    let close: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aucun champ de texte actif")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.hudText)
                    Text("Glissez le texte où vous voulez, ou collez-le avec ⌘V.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.hudSecondary)
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.hudSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Fermer (Échap)")
                .accessibilityLabel("Fermer")
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.wave)
                    .padding(.top, 3)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.hudText)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.wave.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .overlay(DragSource(text: text, onDrop: close))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Texte dicté, à glisser : \(text)")
        }
        .padding(14)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.hudBackground))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hudStroke))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 32)
        .environment(\.colorScheme, .dark)
        .onHover(perform: hover)
    }
}

/// Zone transparente qui lance un glisser-déposer AppKit : SwiftUI ne dit pas quand le dépôt a réussi,
/// et la carte doit partir à ce moment-là.
private struct DragSource: NSViewRepresentable {
    let text: String
    let onDrop: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.text = text
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.text = text
        view.onDrop = onDrop
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var text = ""
    var onDrop: () -> Void = {}
    private var downPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { downPoint = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDrop() }
    }

    /// Image du bloc de texte sous la vue, pour que le glissé ressemble à ce qu'on a pris.
    private func snapshot() -> NSImage? {
        guard let content = window?.contentView else { return nil }
        let rect = convert(bounds, to: content)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}
