import SwiftUI
import AppKit
import ImageIO

/// Le ruban de Murmure en mouvement : 45 images d'une boucle de 1,5 s (30 images par seconde),
/// rendues en 3D avec HyperFrames (motion/ruban-frames) et rangées en grille 9 × 5 dans Resources/RibbonMotion.webp.
/// Le ruban se plie : le vide du milieu se referme presque à mi-boucle, puis revient.
enum RibbonMotion {
    static let frameCount = 45
    private static let columns = 9
    static let fps = 30.0

    /// Les images, découpées une seule fois. Vide si la ressource manque (les vues retombent alors sur Ribbon.png).
    static let frames: [CGImage] = {
        guard let url = Bundle.main.url(forResource: "RibbonMotion", withExtension: "webp"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let rows = (frameCount + columns - 1) / columns
        let w = sheet.width / columns, h = sheet.height / rows
        return (0..<frameCount).compactMap { i in
            sheet.cropping(to: CGRect(x: (i % columns) * w, y: (i / columns) * h, width: w, height: h))
        }
    }()

    /// Largeur sur hauteur d'une image.
    static var aspect: CGFloat {
        guard let f = frames.first else { return 1108.0 / 930.0 }
        return CGFloat(f.width) / CGFloat(f.height)
    }

    /// L'image à afficher pour une position dans la boucle (en boucles : 0,5 = mi-boucle).
    static func frame(at phase: Double) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let i = Int((phase - phase.rounded(.down)) * Double(frameCount)) % frameCount
        return frames[i]
    }

    /// Silhouette pour la barre des menus : macOS teinte l'image selon son canal alpha.
    static func templateImage(phase: Double = 0, height: CGFloat = 16) -> NSImage? {
        guard let cg = frame(at: phase) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: (height * aspect).rounded(), height: height))
        image.isTemplate = true
        image.accessibilityDescription = "Murmure"
        return image
    }

    /// Vitesse de lecture : vive au silence (une boucle en 1,1 s), jusqu'à trois fois plus rapide quand la voix monte.
    static func speed(level: Float) -> Double { 1.35 + 2.4 * Double(min(max(level, 0), 1)) }
}

/// Avance dans la boucle à une vitesse qui peut changer à chaque image, sans saut.
final class RibbonClock {
    private(set) var phase: Double = 0
    private var last: TimeInterval?

    func advance(to now: TimeInterval, speed: Double) -> Double {
        if let last { phase += max(0, min(now - last, 0.1)) * speed / (Double(RibbonMotion.frameCount) / RibbonMotion.fps) }
        last = now
        return phase
    }
}

/// Le ruban vivant : immobile au repos, il se plie en boucle quand `animated` est vrai,
/// plus vite quand la voix monte. `mono` en fait une silhouette d'une seule couleur.
struct RibbonMark: View {
    var height: CGFloat = 18
    var level: Float = 0
    var animated = false
    var mono: Color?
    @State private var clock = RibbonClock()

    var body: some View {
        Group {
            if RibbonMotion.frames.isEmpty {
                RibbonLogo(height: height)
            } else if animated && !Theme.reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / RibbonMotion.fps)) { ctx in
                    picture(clock.advance(to: ctx.date.timeIntervalSinceReferenceDate, speed: RibbonMotion.speed(level: level)))
                }
            } else {
                picture(0)
            }
        }
        .frame(width: height * RibbonMotion.aspect, height: height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func picture(_ phase: Double) -> some View {
        if let cg = RibbonMotion.frame(at: phase) {
            let image = Image(decorative: cg, scale: 1).resizable().interpolation(.high)
            if let mono {
                Rectangle().fill(mono).mask(image)
            } else {
                image
            }
        }
    }
}

/// Le logo fixe : le ruban dessiné (Resources/Ribbon.png).
struct RibbonLogo: View {
    var height: CGFloat = 18

    var body: some View {
        Group {
            if let ribbon = Theme.ribbon {
                Image(nsImage: ribbon).resizable().interpolation(.high).scaledToFit()
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
