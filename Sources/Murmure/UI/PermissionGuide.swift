import AppKit
import SwiftUI

/// Guide posé contre Réglages Système pendant une autorisation : une réplique de la liste où un curseur
/// active l'interrupteur de Murmure, et l'icône de Murmure à glisser dans la liste si elle n'y figure pas.
/// Il suit la fenêtre des Réglages, passe au vert quand l'accès est accordé, puis ramène Murmure au premier plan.
@MainActor
final class PermissionGuide {
    enum Kind {
        case accessibility, microphone

        var isGranted: Bool {
            switch self {
            case .accessibility: return HotkeyMonitor.isTrusted
            case .microphone: return AudioRecorder.permission == .authorized
            }
        }

        func openSettings() {
            switch self {
            case .accessibility:
                // Ajoute Murmure à la liste (désactivé) avant d'ouvrir le bon panneau.
                HotkeyMonitor.promptForAccessibility()
                HotkeyMonitor.openAccessibilitySettings()
            case .microphone:
                HotkeyMonitor.openMicrophoneSettings()
            }
        }
    }

    static let shared = PermissionGuide()
    private let model = PermissionGuideModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var sawSettings = false
    private var started = Date()

    /// Ouvre le bon panneau des Réglages et y accroche le guide.
    func start(_ kind: Kind) {
        model.kind = kind
        model.granted = kind.isGranted
        kind.openSettings()
        sawSettings = false
        started = Date()
        if panel == nil { panel = makePanel() }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        guard let panel else { return }
        if model.kind.isGranted {
            guard !model.granted else { return }
            model.granted = true
            // Le temps de voir l'interrupteur passer au vert, puis retour dans Murmure.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                self?.stop()
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        guard let frame = Self.settingsWindowFrame() else {
            // Réglages fermés sans accorder l'accès : le guide s'arrête. Pas encore ouverts : il attend.
            if sawSettings || Date().timeIntervalSince(started) > 15 { stop() } else { panel.orderOut(nil) }
            return
        }
        sawSettings = true
        place(panel, beside: frame)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: PermissionGuideCard(model: model) { [weak self] in self?.stop() })
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }

    /// À droite de la fenêtre des Réglages, à hauteur de la liste ; à gauche s'il n'y a pas la place ;
    /// sinon posé dans son coin bas droit.
    private func place(_ panel: NSPanel, beside settings: CGRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) })?.visibleFrame ?? .zero
        let top = settings.maxY - 120
        var origin = CGPoint(x: settings.maxX + 14, y: top - size.height)
        if origin.x + size.width > screen.maxX {
            origin.x = settings.minX - 14 - size.width
            if origin.x < screen.minX {
                origin = CGPoint(x: settings.maxX - size.width - 18, y: settings.minY + 18)
            }
        }
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// Cadre de la fenêtre de Réglages Système, en coordonnées de l'écran (origine en bas à gauche).
    private static func settingsWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  rect.width > 200, rect.height > 200 else { continue }
            return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

@MainActor
final class PermissionGuideModel: ObservableObject {
    @Published var kind: PermissionGuide.Kind = .accessibility
    @Published var granted = false
}

/// La carte flottante : la réplique animée, et l'icône à glisser.
struct PermissionGuideCard: View {
    @ObservedObject var model: PermissionGuideModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: model.granted ? "checkmark.circle.fill" : "hand.point.up.left.fill")
                    .foregroundStyle(model.granted ? Palette.ok : Theme.voice)
                Text(model.granted ? "C'est autorisé" : "Activez Ramage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Palette.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer le guide")
            }
            SettingsToggleDemo(granted: model.granted)
            if model.kind == .accessibility && !model.granted {
                DragAppHint()
            }
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(Palette.ink)
        .background {
            ZStack {
                VisualEffect(material: .popover)
                Palette.panel
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .animation(Theme.quick, value: model.granted)
    }
}

/// « Pas dans la liste ? » : l'icône de Murmure se glisse dans la liste des Réglages.
private struct DragAppHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Glissez Ramage dans la liste des Réglages")
            Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.voice)
            Text("Absent de la liste ? Glissez l'icône.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
    }
}

/// Réplique d'une liste des Réglages : la ligne de Murmure, et un curseur qui vient activer son interrupteur.
/// En boucle tant que l'accès n'est pas accordé ; figée, interrupteur allumé, si les animations sont réduites.
struct SettingsToggleDemo: View {
    var granted = false
    private let loop = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: granted || Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
            frame(t: granted || Theme.reduceMotion ? 1.4 : t)
        }
        .accessibilityElement()
        .accessibilityLabel("Dans la liste, activez l'interrupteur à côté de Ramage.")
    }

    /// 0 à 1 : le curseur arrive ; 1 à 1,15 : il clique ; ensuite l'interrupteur est allumé.
    private func frame(t: Double) -> some View {
        let arrive = min(1, t / 1.0)
        let ease = 1 - pow(1 - arrive, 3)
        let pressing = t > 1.0 && t < 1.15
        let on = granted || t >= 1.1
        return VStack(spacing: 0) {
            placeholderRow
            Divider().opacity(0.5)
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("Ramage").font(.system(size: 12, weight: .medium))
                Spacer()
                ToggleShape(on: on, accent: granted ? Palette.ok : Color(nsColor: .controlAccentColor))
                    .scaleEffect(pressing ? 0.92 : 1)
                    .overlay(alignment: .topLeading) {
                        if !granted {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 17))
                                .foregroundStyle(.black)
                                .shadow(color: .white, radius: 0.5)
                                .scaleEffect(pressing ? 0.85 : 1)
                                .offset(x: 14 + (1 - ease) * 46, y: 6 + (1 - ease) * 34)
                                .opacity(t > loop - 0.3 ? (loop - t) / 0.3 : 1)
                        }
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(on ? Color(nsColor: .controlAccentColor).opacity(granted ? 0 : 0.06) : .clear)
            Divider().opacity(0.5)
            placeholderRow
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .animation(.easeOut(duration: 0.18), value: on)
    }

    private var placeholderRow: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5).fill(Palette.hairline).frame(width: 22, height: 22)
            Capsule().fill(Palette.hairline).frame(width: 74, height: 6)
            Spacer()
            ToggleShape(on: false, accent: .clear).opacity(0.6)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// Réplique de l'alerte de macOS qui demande le micro, et un curseur qui va cliquer sur « Autoriser ».
struct MicrophoneAlertDemo: View {
    var granted = false
    private let loop = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: granted || Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
            frame(t: granted || Theme.reduceMotion ? 1.4 : t)
        }
        .accessibilityElement()
        .accessibilityLabel("Dans l'alerte de macOS, cliquez sur Autoriser.")
    }

    private func frame(t: Double) -> some View {
        let arrive = min(1, t / 1.0)
        let ease = 1 - pow(1 - arrive, 3)
        let pressing = t > 1.0 && t < 1.18
        return VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(spacing: 5) {
                Capsule().fill(Palette.ink.opacity(0.75)).frame(width: 150, height: 7)
                Capsule().fill(Palette.hairline).frame(width: 120, height: 5)
                Capsule().fill(Palette.hairline).frame(width: 96, height: 5)
            }
            HStack(spacing: 8) {
                Text("Ne pas autoriser")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 104, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.hairline))
                Text("Autoriser")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor).opacity(pressing ? 0.75 : 1)))
                    .scaleEffect(pressing ? 0.95 : 1)
                    .overlay(alignment: .topLeading) {
                        if !granted {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 17))
                                .foregroundStyle(.black)
                                .shadow(color: .white, radius: 0.5)
                                .scaleEffect(pressing ? 0.85 : 1)
                                .offset(x: 58 + (1 - ease) * 40, y: 10 + (1 - ease) * 40)
                                .opacity(t > loop - 0.3 ? (loop - t) / 0.3 : 1)
                        }
                    }
            }
        }
        .padding(16)
        .frame(width: 252)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.raised)
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

/// Interrupteur façon macOS.
private struct ToggleShape: View {
    let on: Bool
    let accent: Color

    var body: some View {
        Capsule()
            .fill(on ? accent : Palette.hairline.opacity(2.2))
            .frame(width: 28, height: 16)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 14, height: 14).padding(1)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            }
    }
}
