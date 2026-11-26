// Fond de la fenêtre du DMG : une flèche qui va de Murmure vers une zone de dépôt autour d'Applications.
// Pas de texte : le geste se comprend tout seul.
// Usage : swift Scripts/dmg/make-background.swift Scripts/dmg
//         tiffutil -cathidpicheck Scripts/dmg/background.png Scripts/dmg/background@2x.png -out Scripts/dmg/background.tiff
// Seul background.tiff (1x + 2x) est gardé dans le dépôt.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// Même géométrie que settings.py : fenêtre 660 × 400, icônes centrées en (170, 190) et (490, 190).
let size = CGSize(width: 660, height: 400)
let app = CGPoint(x: 170, y: 190), apps = CGPoint(x: 490, y: 190)
let iris = NSColor(srgbRed: 0.290, green: 0.314, blue: 0.600, alpha: 1)

func render(scale: CGFloat) -> Data {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // Repère du haut vers le bas, comme Finder.
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)

    // Fond : le gris bleuté de Murmure, un peu plus clair en haut.
    let bg = NSGradient(colors: [NSColor(srgbRed: 0.973, green: 0.976, blue: 0.992, alpha: 1),
                                 NSColor(srgbRed: 0.918, green: 0.929, blue: 0.965, alpha: 1)])!
    bg.draw(in: CGRect(origin: .zero, size: size), angle: 90)

    // Zone de dépôt autour d'Applications : un cadre pointillé.
    let zone = CGRect(x: apps.x - 84, y: apps.y - 82, width: 168, height: 182)
    let zonePath = NSBezierPath(roundedRect: zone, xRadius: 34, yRadius: 34)
    iris.withAlphaComponent(0.06).setFill()
    zonePath.fill()
    iris.withAlphaComponent(0.35).setStroke()
    zonePath.lineWidth = 2
    zonePath.setLineDash([7, 7], count: 2, phase: 0)
    zonePath.lineCapStyle = .round
    zonePath.stroke()

    // Flèche courbe de Murmure vers Applications.
    let start = CGPoint(x: app.x + 78, y: app.y - 18), end = CGPoint(x: apps.x - 98, y: apps.y - 18)
    let control = CGPoint(x: (start.x + end.x) / 2, y: app.y - 92)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: CGPoint(x: start.x + (control.x - start.x) * 0.66, y: start.y + (control.y - start.y) * 0.66),
                controlPoint2: CGPoint(x: end.x + (control.x - end.x) * 0.66, y: end.y + (control.y - end.y) * 0.66))
    iris.withAlphaComponent(0.85).setStroke()
    arrow.lineWidth = 4
    arrow.setLineDash([2, 11], count: 2, phase: 0)
    arrow.lineCapStyle = .round
    arrow.stroke()

    // Pointe : orientée selon la fin de la courbe.
    let dir = atan2(end.y - (end.y + (control.y - end.y) * 0.66), end.x - (end.x + (control.x - end.x) * 0.66))
    let head = NSBezierPath()
    let l: CGFloat = 16, a: CGFloat = .pi / 5
    head.move(to: CGPoint(x: end.x - l * cos(dir - a), y: end.y - l * sin(dir - a)))
    head.line(to: end)
    head.line(to: CGPoint(x: end.x - l * cos(dir + a), y: end.y - l * sin(dir + a)))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Étape suivante, en une ligne sous les icônes : sans elle, on ne sait pas quoi faire après le glisser.
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let hint = NSMutableAttributedString(string: "Puis ouvrez Murmure depuis Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.357, green: 0.392, blue: 0.471, alpha: 1),
        .paragraphStyle: para])
    // Le repère est retourné : on remet le texte à l'endroit le temps de le dessiner.
    cg.saveGState()
    cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
    hint.draw(in: CGRect(x: 0, y: 34, width: size.width, height: 20))
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))
print("écrit : \(out)/background.png et background@2x.png")
