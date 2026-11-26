// Les trois sons de Murmure, synthétisés ici pour qu'ils soient doux, courts et à nous :
//   start.wav  : deux notes qui montent (la dictée s'ouvre)
//   stop.wav   : les mêmes qui redescendent, plus courtes (c'est parti au traitement)
//   cancel.wav : une note grave et feutrée (annulé)
// Chaque note : attaque de 3 ms, petit glissé vers le haut, décroissance exponentielle,
// deux harmoniques discrètes et une queue de réverbération légère. Rien qui claque.
// Usage : swift Scripts/sounds/make-sounds.swift Resources/Sounds
import Foundation

let rate = 48_000.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

struct Note { let freq: Double; let at: Double; let decay: Double; let gain: Double }

func render(_ notes: [Note], length: Double, warmth: Double = 0.18) -> [Double] {
    let n = Int(length * rate)
    var buf = [Double](repeating: 0, count: n)
    for note in notes {
        let start = Int(note.at * rate)
        var phase = 0.0
        for i in start..<n {
            let t = Double(i - start) / rate
            // Glissé : la note part 1,5 % plus bas et rejoint sa hauteur en 25 ms.
            let f = note.freq * (1 - 0.015 * exp(-t / 0.008))
            phase += 2 * .pi * f / rate
            let attack = min(1, t / 0.003)
            let env = attack * exp(-t / note.decay)
            if env < 0.0005 && t > 0.05 { break }
            let tone = sin(phase) + warmth * sin(2 * phase) * exp(-t / (note.decay * 0.5)) + 0.05 * sin(3 * phase) * exp(-t / (note.decay * 0.3))
            buf[i] += note.gain * env * tone
        }
    }
    // Réverbération : quelques échos courts et amortis, pour l'air autour du son.
    var wet = buf
    for (delay, g) in [(0.023, 0.18), (0.037, 0.13), (0.051, 0.09), (0.071, 0.06)] {
        let d = Int(delay * rate)
        for i in d..<n { wet[i] += g * buf[i - d] }
    }
    // Fondu de sortie et normalisation à -14 dBFS crête : présent sans être fort.
    let fade = Int(0.03 * rate)
    for i in 0..<fade { wet[n - 1 - i] *= Double(i) / Double(fade) }
    let peak = wet.map(abs).max() ?? 1
    let target = pow(10, -14.0 / 20)
    return wet.map { $0 / peak * target }
}

func writeWAV(_ samples: [Double], to path: String) {
    var data = Data()
    func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; data.append(Data(bytes: &x, count: MemoryLayout<T>.size)) }
    let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
    data.append("RIFF".data(using: .ascii)!); le(UInt32(36 + pcm.count * 2))
    data.append("WAVEfmt ".data(using: .ascii)!); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
    le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
    data.append("data".data(using: .ascii)!); le(UInt32(pcm.count * 2))
    for s in pcm { le(s) }
    try! data.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
// Do5 → Sol5 : une quinte ouverte, claire et calme.
writeWAV(render([Note(freq: 523.25, at: 0, decay: 0.09, gain: 0.8),
                 Note(freq: 783.99, at: 0.055, decay: 0.16, gain: 1.0)], length: 0.42), to: "\(out)/start.wav")
// Sol5 → Do5, plus court : on referme.
writeWAV(render([Note(freq: 783.99, at: 0, decay: 0.06, gain: 0.7),
                 Note(freq: 523.25, at: 0.045, decay: 0.12, gain: 0.9)], length: 0.34), to: "\(out)/stop.wav")
// Une seule note grave et sourde.
writeWAV(render([Note(freq: 293.66, at: 0, decay: 0.1, gain: 1.0)], length: 0.3, warmth: 0.05), to: "\(out)/cancel.wav")
print("écrit : start.wav, stop.wav, cancel.wav dans \(out)")
