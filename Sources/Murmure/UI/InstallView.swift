import AppKit
import SwiftUI

/// Murmure lancé depuis le DMG : une seule fenêtre, un seul bouton, et il se range dans Applications.
@MainActor
final class InstallWindow: NSObject, NSWindowDelegate {
    static let shared = InstallWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: InstallView())
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = "Murmure"
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Fermer cette fenêtre sans installer : rien d'autre ne tourne depuis le DMG, on quitte.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

struct InstallView: View {
    private enum State: Equatable { case idle, working, failed(String) }
    @SwiftUI.State private var state: State = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InstallArt(moving: state != .working)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 8) {
                Text("Installer Murmure")
                    .font(.system(size: 24, weight: .medium))
                    .tracking(-0.5)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Spacer()
                switch state {
                case .idle:
                    PrimaryButton("Installer", action: install)
                case .working:
                    ProgressView().controlSize(.small)
                    Text("Installation…").font(.system(size: 13)).foregroundStyle(Palette.muted)
                case .failed:
                    PrimaryButton("Réessayer", prominent: false, action: install)
                    PrimaryButton("Ouvrir Applications") { Installer.revealApplications() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .frame(height: 74)
        }
        .frame(width: OnboardingView.size.width, height: OnboardingView.size.height)
        .foregroundStyle(Palette.ink)
        .background(Palette.card)
        .tint(Theme.voice)
        .animation(Theme.quick, value: state)
    }

    private var message: String {
        switch state {
        case .idle, .working: return "Il se range dans Applications, puis se rouvre tout seul."
        case .failed: return "Impossible de le copier. Glissez l'icône de Murmure dans le dossier Applications."
        }
    }

    private func install() {
        state = .working
        Task {
            do { try await Installer.install() } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}

/// L'icône de Murmure glisse dans le dossier Applications, en boucle. Elle se laisse aussi glisser pour de vrai.
private struct InstallArt: View {
    var moving = true
    private let loop = 2.8
    private let folder: NSImage = {
        let icon = NSWorkspace.shared.icon(forFile: "/Applications")
        icon.size = NSSize(width: 256, height: 256)  // sinon macOS donne la version 32 px, floue une fois agrandie
        return icon
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !moving || Theme.reduceMotion)) { ctx in
            let t = moving && !Theme.reduceMotion
                ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop) : 0
            frame(t: t)
        }
        .accessibilityElement()
        .accessibilityLabel("Murmure va dans le dossier Applications.")
    }

    /// 0,3 à 1,6 s : l'icône part vers le dossier ; 1,6 à 2 s : elle y entre, le dossier rebondit.
    private func frame(t: Double) -> some View {
        let go = min(1, max(0, (t - 0.3) / 1.3))
        let ease = go < 0.5 ? 4 * go * go * go : 1 - pow(-2 * go + 2, 3) / 2
        let sink = min(1, max(0, (t - 1.6) / 0.4))
        let bump = t > 1.6 && t < 2.1 ? sin((t - 1.6) / 0.5 * .pi) * 0.08 : 0
        let lift = go > 0 && sink == 0 ? 1.08 : 1.0
        return ZStack {
            DashedArc()
                .stroke(Theme.voice.opacity(0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1.5, 8]))
                .frame(width: 120, height: 40)
                .offset(y: -36)
            Image(nsImage: folder)
                .resizable()
                .frame(width: 96, height: 96)
                .scaleEffect(1 + bump)
                .offset(x: 90)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(go > 0 && sink == 0 ? 0.18 : 0.08), radius: go > 0 ? 10 : 4, y: go > 0 ? 6 : 2)
                .scaleEffect(lift * (1 - 0.6 * sink))
                .opacity((t == 0 ? 1 : min(1, t / 0.25)) * (1 - sink))
                .offset(x: -90 + 180 * ease, y: -24 * sin(ease * .pi))
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Glissez Murmure dans le dossier Applications")
        }
        .frame(width: 320, height: 160)
    }
}

/// Arc pointillé entre l'app et le dossier, comme sur la fenêtre du DMG.
private struct DashedArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.4))
        return p
    }
}
