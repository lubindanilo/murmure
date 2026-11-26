import SwiftUI
import AppKit

/// Le ruban de Murmure dessiné en code, pour qu'il puisse bouger avec la voix.
/// Une bande refermée sur elle-même, tordue d'un demi-tour en haut et en bas, faite de fines lignes :
/// violet à gauche, turquoise à droite, comme Resources/Ribbon.png.
/// `t` est le temps en secondes, `level` le niveau de la voix (0 à 1).
enum Ribbon {
    /// Cadre du ruban au repos, qui sert à le placer : la voix le fait déborder d'un peu moins de 10 %.
    private static let rest: CGRect = {
        let pts = grid(t: 0, level: 0, lines: 2, steps: 360, band: 1).flatMap { $0 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }()
    /// Largeur sur hauteur du dessin.
    static var aspect: CGFloat { rest.width / rest.height }

    private struct Sample { let x: Double; let y: Double; let psi: Double }

    private static func radius(_ th: Double, _ t: Double, _ level: Double) -> Double {
        1 + 0.05 * cos(3 * th) + 0.02 * sin(2 * th + t * 0.8) + level * 0.045 * sin(4 * th - t * 7)
    }

    private static func grid(t: Double, level: Double, lines: Int, steps: Int, band: Double) -> [[Sample]] {
        (0...steps).map { i in
            let th = Double(i) / Double(steps) * 2 * .pi
            let r = radius(th, t, level)
            let cx = cos(th) * r, cy = sin(th) * 0.86 * r
            let th2 = th + 0.001, r2 = radius(th2, t, level)
            let dx = cos(th2) * r2 - cx, dy = sin(th2) * 0.86 * r2 - cy
            let len = max(hypot(dx, dy), 1e-9)
            let nx = -dy / len, ny = dx / len
            // La bande tourne sur elle-même : sa largeur apparente s'annule en haut et en bas.
            let psi = th + 0.22 * sin(t * 0.5)
            let neck = 1 - 0.45 * exp(-pow((th - .pi - 0.35) / 0.4, 2))
            let w = 0.36 * band * (1 + 0.2 * cos(th)) * neck * (1 + 0.14 * level) * cos(psi)
            return (0...lines).map { j in
                let k = -1 + 2 * Double(j) / Double(lines)
                return Sample(x: cx + nx * w * k, y: cy + ny * w * k, psi: psi)
            }
        }
    }

    /// Parcourt les petits quadrilatères qui forment le ruban, déjà placés dans `size`.
    private static func forEachQuad(size: CGSize, t: Double, level: Double, height: CGFloat, band: Double = 1,
                                    _ body: (_ quad: [CGPoint], _ th: Double, _ psi: Double, _ j: Int, _ lines: Int) -> Void) {
        let lines = height < 40 ? 12 : 30
        let steps = height < 40 ? 84 : 200
        let g = grid(t: t, level: level, lines: lines, steps: steps, band: band)
        let s = min(size.width / rest.width, size.height / rest.height) * 0.9
        let ox = size.width / 2 - rest.midX * s, oy = size.height / 2 - rest.midY * s
        let tilt = 0.05 * sin(t * 0.3), ct = cos(tilt), st = sin(tilt)
        func pt(_ p: Sample) -> CGPoint {
            CGPoint(x: ox + (p.x * ct - p.y * st) * s, y: oy + (p.x * st + p.y * ct) * s)
        }
        for i in 0..<steps {
            let th = (Double(i) + 0.5) / Double(steps) * 2 * .pi
            for j in 0..<lines {
                let a = g[i][j], b = g[i + 1][j], c = g[i + 1][j + 1], d = g[i][j + 1]
                body([pt(a), pt(b), pt(c), pt(d)], th, a.psi, j, lines)
            }
        }
    }

    private static let violet: [Double] = [58, 62, 150], violetLight: [Double] = [205, 205, 250]
    private static let teal: [Double] = [40, 118, 138], tealLight: [Double] = [178, 222, 242]

    /// Couleur d'une ligne : violet à gauche, turquoise à droite, éclairée selon l'angle de la bande.
    private static func color(th: Double, psi: Double, j: Int, lines: Int) -> Color {
        func mix(_ a: [Double], _ b: [Double], _ f: Double) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * f } }
        let side = (cos(th) + 1) / 2
        let f = side * side * (3 - 2 * side)
        let dark = mix(violet, teal, f), light = mix(violetLight, tealLight, f)
        let k = (Double(j) + 0.5) / Double(lines) * 2 - 1
        let facing = abs(cos(psi)), turn = cos(psi) >= 0 ? 1.0 : -1.0
        let sheen = 0.5 + 0.45 * sin(psi) * turn
        let lum = min(1, max(0, 0.05 + 0.8 * sheen * (0.55 + 0.45 * facing) + 0.22 * k * turn))
        let stripe = j % 2 == 0 ? 1.06 : 0.97
        let c = mix(dark, light, lum).map { min(255, $0 * stripe) / 255 }
        return Color(red: c[0], green: c[1], blue: c[2])
    }

    /// Dessine le ruban en couleur, ou d'une seule teinte si `mono` est donné.
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, level: Double, mono: Color?) {
        let seam = size.height < 40 ? 0.3 : 0.5
        forEachQuad(size: size, t: t, level: level, height: size.height) { quad, th, psi, j, lines in
            var path = Path()
            path.addLines(quad)
            path.closeSubpath()
            let fill = mono ?? color(th: th, psi: psi, j: j, lines: lines)
            ctx.fill(path, with: .color(fill))
            ctx.stroke(path, with: .color(fill), lineWidth: seam)
        }
    }

    /// Silhouette pour la barre des menus (image modèle, teintée par macOS).
    static func templateImage(t: Double = 0, level: Double = 0, height: CGFloat = 16) -> NSImage {
        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(NSColor.black.cgColor)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineWidth(0.3)
            // Bande plus fine qu'en couleur : à 16 pt, le trou du ruban reste lisible.
            forEachQuad(size: rect.size, t: t, level: level, height: rect.height, band: 0.72) { quad, _, _, _, _ in
                cg.addLines(between: quad)
                cg.closePath()
                cg.drawPath(using: .fillStroke)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Murmure"
        return image
    }
}

/// Le ruban vivant : immobile au repos, il ondule avec la voix quand `animated` est vrai.
struct RibbonMark: View {
    var height: CGFloat = 18
    var level: Float = 0
    var animated = false
    var mono: Color?

    var body: some View {
        Group {
            if animated && !Theme.reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    canvas(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(t: 0)
            }
        }
        .frame(width: height * Ribbon.aspect, height: height)
        .accessibilityHidden(true)
    }

    private func canvas(t: Double) -> some View {
        Canvas { ctx, size in
            Ribbon.draw(&ctx, size: size, t: t, level: Double(level), mono: mono)
        }
    }
}

/// Le logo fixe : le ruban dessiné (Resources/Ribbon.png), ou sa version en code s'il manque.
struct RibbonLogo: View {
    var height: CGFloat = 18

    var body: some View {
        Group {
            if let ribbon = Theme.ribbon {
                Image(nsImage: ribbon).resizable().interpolation(.high).scaledToFit()
            } else {
                RibbonMark(height: height)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
