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
              let webp = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: webp.width, height: webp.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        // Les découpes d'un WebP décodé à la demande redécodent toute la planche à chaque rendu.
        bitmap.draw(webp, in: CGRect(x: 0, y: 0, width: webp.width, height: webp.height))
        guard let sheet = bitmap.makeImage() else { return [] }
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
        image.accessibilityDescription = "Ramage"
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

/// Animation du ruban du bandeau. Les fondus sont composés une fois dans une seule texture Retina.
@MainActor
final class HUDRibbon {
    static let height: CGFloat = 20
    static var width: CGFloat { (height * RibbonMotion.aspect).rounded() }
    private static let baseSpeed: Float = 1.15

    nonisolated static let sprite: Sprite? = makeSprite()

    struct Sprite: Sendable {
        let image: CGImage
        let cells: [CGRect]
        let duration: CFTimeInterval
    }

    nonisolated private static func makeSprite() -> Sprite? {
        let frames = RibbonMotion.frames
        guard !frames.isEmpty else { return nil }
        let steps = 6
        let count = frames.count * steps
        let columns = 15
        let rows = (count + columns - 1) / columns
        let pixelHeight = 60
        let pixelWidth = Int((CGFloat(pixelHeight) * RibbonMotion.aspect).rounded())
        // Deux pixels transparents séparent les cellules, même avec le filtrage bilinéaire.
        let cellWidth = pixelWidth + 2
        let cellHeight = pixelHeight + 2
        let width = columns * cellWidth
        let height = rows * cellHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        var cells: [CGRect] = []
        for index in 0..<count {
            let current = index / steps
            let fraction = CGFloat(index % steps) / CGFloat(steps)
            let x = index % columns * cellWidth + 1
            let y = index / columns * cellHeight + 1
            let rect = CGRect(x: x, y: height - y - pixelHeight, width: pixelWidth, height: pixelHeight)
            context.setBlendMode(.copy)
            context.setAlpha(1 - fraction)
            context.draw(frames[current], in: rect)
            if fraction > 0 {
                context.setBlendMode(.plusLighter)
                context.setAlpha(fraction)
                context.draw(frames[(current + 1) % frames.count], in: rect)
            }
            cells.append(CGRect(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height),
                                width: CGFloat(pixelWidth) / CGFloat(width),
                                height: CGFloat(pixelHeight) / CGFloat(height)))
        }
        guard let image = context.makeImage() else { return nil }
        return Sprite(image: image, cells: cells, duration: Double(frames.count) / RibbonMotion.fps)
    }

    let layer = CALayer()
    private let image = CALayer()
    private var running = false
    private var speed = HUDRibbon.baseSpeed
    private var scale: CGFloat = 1

    init() {
        layer.addSublayer(image)
    }

    func place(in rect: CGRect, backingScale: CGFloat) {
        layer.frame = rect
        image.frame = layer.bounds
        image.contentsScale = backingScale
    }

    func start(reduceMotion: Bool) {
        guard !running else { return }
        guard let sprite = Self.sprite, let first = sprite.cells.first else {
            image.contents = Theme.ribbon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return
        }
        image.contents = sprite.image
        image.contentsRect = first
        guard !reduceMotion else { return }

        running = true
        let loop = CAKeyframeAnimation(keyPath: "contentsRect")
        loop.values = (sprite.cells + [first]).map { NSValue(rect: $0) }
        loop.calculationMode = .discrete
        loop.duration = sprite.duration
        loop.repeatCount = .infinity
        image.speed = speed
        image.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        image.add(loop, forKey: "loop")
    }

    func stop() {
        guard running else { return }
        running = false
        image.removeAnimation(forKey: "loop")
        image.speed = 1
        image.timeOffset = 0
        image.beginTime = 0
        speed = Self.baseSpeed
        scale = 1
        layer.removeAnimation(forKey: "scale")
        layer.setAffineTransform(.identity)
    }

    func setLevel(_ level: Float) {
        guard running else { return }
        let level = min(max(level, 0), 1)
        let nextSpeed = speed + (Self.baseSpeed + 1.6 * level - speed) * 0.35
        let nextScale = 1 + 0.14 * CGFloat(level)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if abs(nextSpeed - speed) > 0.02 {
            // La position locale de la boucle reste la même quand sa vitesse change.
            let now = CACurrentMediaTime()
            let elapsed = image.convertTime(now, from: nil)
            image.speed = nextSpeed
            image.timeOffset = elapsed
            image.beginTime = layer.convertTime(now, from: nil)
            speed = nextSpeed
        }
        if nextScale != scale {
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = layer.presentation()?.affineTransform().a ?? scale
            animation.toValue = nextScale
            animation.duration = 0.12
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.setAffineTransform(CGAffineTransform(scaleX: nextScale, y: nextScale))
            layer.add(animation, forKey: "scale")
            scale = nextScale
        }
        CATransaction.commit()
    }
}
