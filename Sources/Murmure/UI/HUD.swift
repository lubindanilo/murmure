import AppKit
import SwiftUI

/// Petit panneau flottant en bas de l'écran pendant la dictée.
/// Il ne prend jamais le focus : l'utilisateur reste dans son app.
@MainActor
final class HUDController {
    private weak var controller: AppController?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    init(controller: AppController) { self.controller = controller }

    func show() {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.reduceMotion ? 0 : 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.reduceMotion ? 0 : 0.22
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    self.controller?.resetIfFinished()
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Les zones transparentes laissent passer les clics ; seul le sélecteur de mode est cliquable.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        if let controller {
            let host = NSHostingView(rootView: HUDView().environmentObject(controller))
            host.frame = panel.contentRect(forFrameRect: panel.frame)
            panel.contentView = host
        }
        return panel
    }

    /// Centré en bas de l'écran où se trouve la souris, au-dessus du Dock.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}

struct HUDView: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            capsule
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 64)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            content
        }
        .id(phaseKey)
        .transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)).combined(with: .modifier(active: BlurModifier(radius: 3), identity: BlurModifier(radius: 0))))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.hudBackground)
                .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
                .shadow(color: .black.opacity(0.20), radius: 2, y: 1)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.hudStroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .animation(Theme.reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0), value: phaseKey)
    }

    private var phaseKey: String {
        switch app.phase {
        case .idle: return "idle"
        case .recording(let free): return free ? "free" : "hold"
        case .transcribing: return "transcribing"
        case .polishing: return "polishing"
        case .translating: return "translating"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.phase {
        case .recording(let handsFree):
            Waveform(level: app.level, active: true)
            if handsFree {
                Text("mains libres")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.hudSecondary)
            }
            ModeChip()
        case .transcribing:
            Waveform(level: 0, active: false)
            Text("Transcription")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.hudText)
        case .polishing(let mode):
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.voice)
            Text(mode)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.hudText)
        case .translating(let language):
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.voice)
            Text("Traduction en \(language.lowercased())")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.hudText)
        case .done(let label):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.green)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.hudText)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.voice)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.hudText)
                .lineLimit(2)
                .frame(maxWidth: 330, alignment: .leading)
        case .idle:
            EmptyView()
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Barres qui suivent la voix. Au repos (transcription), une vague lente les parcourt.
struct Waveform: View {
    let level: Float
    let active: Bool
    private let bars = 9
    /// Profil en cloche : les barres centrales réagissent plus fort.
    private let profile: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(active ? Theme.voice : Color.white.opacity(0.55))
                        .frame(width: 3, height: height(i, t))
                }
            }
            .frame(height: 22)
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let minH: CGFloat = 3
        if active {
            let jitter = CGFloat(0.75 + 0.25 * sin(t * 13 + Double(i) * 1.7))
            return minH + CGFloat(level) * 19 * profile[i] * jitter
        }
        if Theme.reduceMotion { return 6 }
        let wave = (sin(t * 5 - Double(i) * 0.7) + 1) / 2
        return minH + CGFloat(wave) * 9
    }
}

/// Nom du mode en cours ; cliquer permet d'en changer pendant l'enregistrement.
struct ModeChip: View {
    @EnvironmentObject var app: AppController
    @ObservedObject private var store = ModeStore.shared

    var body: some View {
        if store.modes.count > 1, let mode = app.currentMode {
            Menu {
                ForEach(store.modes) { m in
                    Button { app.switchCurrentMode(to: m) } label: { Label(m.name, systemImage: m.symbol) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: mode.symbol).font(.system(size: 10, weight: .semibold))
                    Text(mode.name).font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.hudSecondary)
                }
                .foregroundStyle(Theme.hudText)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Changer de mode pour cette dictée")
        }
    }
}
