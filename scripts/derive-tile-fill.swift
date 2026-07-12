import AppKit
import Foundation

// --- OKLab conversions (Björn Ottosson reference) ---
func srgbToLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func linearToSrgb(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055 }

struct OKLab { var L: Double; var a: Double; var b: Double }

func rgbToOKLab(_ r: Double, _ g: Double, _ b: Double) -> OKLab {
    let lr = srgbToLinear(r), lg = srgbToLinear(g), lb = srgbToLinear(b)
    let l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
    let m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
    let s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb
    let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
    return OKLab(
        L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    )
}

func oklabToRGB(_ lab: OKLab) -> (Double, Double, Double) {
    let l_ = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b
    let m_ = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b
    let s_ = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b
    let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
    let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (
        min(max(linearToSrgb(r), 0), 1),
        min(max(linearToSrgb(g), 0), 1),
        min(max(linearToSrgb(b), 0), 1)
    )
}

func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
    String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
}

// --- load + downsample ---
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot load \(path)"); exit(1)
}
let w = 302, h = 180
let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)

var pixels: [(Double, Double, Double)] = []
for y in 0..<h {
    for x in 0..<w {
        // skip traffic-light corner (top-left ~120x40 pt of 1512x958)
        if x < 26, y > h - 12 { continue }   // context is y-flipped: top row = high y
        let i = (y * w + x) * 4
        pixels.append((Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255))
    }
}

// --- k-means, k=6 ---
var centers: [(Double, Double, Double)] = (0..<6).map { i in pixels[i * pixels.count / 6] }
var assignment = [Int](repeating: 0, count: pixels.count)
for _ in 0..<12 {
    for (pi, p) in pixels.enumerated() {
        var best = 0; var bestD = Double.infinity
        for (ci, c) in centers.enumerated() {
            let d = pow(p.0 - c.0, 2) + pow(p.1 - c.1, 2) + pow(p.2 - c.2, 2)
            if d < bestD { bestD = d; best = ci }
        }
        assignment[pi] = best
    }
    var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: 6)
    for (pi, p) in pixels.enumerated() {
        let a = assignment[pi]
        sums[a] = (sums[a].0 + p.0, sums[a].1 + p.1, sums[a].2 + p.2, sums[a].3 + 1)
    }
    for ci in 0..<6 where sums[ci].3 > 0 {
        centers[ci] = (sums[ci].0 / Double(sums[ci].3), sums[ci].1 / Double(sums[ci].3), sums[ci].2 / Double(sums[ci].3))
    }
}
var counts = [Int](repeating: 0, count: 6)
for a in assignment { counts[a] += 1 }

print("=== clusters (canvas floor, outside terminals) ===")
let order = (0..<6).sorted { counts[$0] > counts[$1] }
for ci in order where counts[ci] > 0 {
    let c = centers[ci]
    let lab = rgbToOKLab(c.0, c.1, c.2)
    let chroma = sqrt(lab.a * lab.a + lab.b * lab.b)
    let hue = atan2(lab.b, lab.a) * 180 / .pi
    print(String(
        format: "%@  %5.1f%%   OKLCH L=%.3f C=%.4f H=%.0f°",
        hex(c.0, c.1, c.2), 100 * Double(counts[ci]) / Double(pixels.count), lab.L, chroma, hue < 0 ? hue + 360 : hue
    ))
}

// --- overall stats ---
var sumL = 0.0, sumA = 0.0, sumB = 0.0
for p in pixels {
    let lab = rgbToOKLab(p.0, p.1, p.2)
    sumL += lab.L; sumA += lab.a; sumB += lab.b
}
let n = Double(pixels.count)
let meanLab = OKLab(L: sumL / n, a: sumA / n, b: sumB / n)
let meanChroma = sqrt(meanLab.a * meanLab.a + meanLab.b * meanLab.b)
var meanHue = atan2(meanLab.b, meanLab.a) * 180 / .pi
if meanHue < 0 { meanHue += 360 }
print(String(format: "\nfloor mean: %@  OKLCH L=%.3f C=%.4f H=%.0f°",
             hex(oklabToRGB(meanLab).0, oklabToRGB(meanLab).1, oklabToRGB(meanLab).2), meanLab.L, meanChroma, meanHue))

// --- derive fill candidates ---
// Analogous-harmony rule: keep the floor's hue, keep chroma at or slightly
// above the floor's (so the tile doesn't look grayer/deader than its
// surroundings), and set lightness well below the floor so tiles read as
// carved-in glass. Try a small L ladder around ~55-65% of floor L.
print("\n=== derived fill candidates (floor hue preserved) ===")
let hueRad = atan2(meanLab.b, meanLab.a)
let fillChroma = max(meanChroma, 0.008)
for fillL in [meanLab.L * 0.52, meanLab.L * 0.58, meanLab.L * 0.65] {
    let lab = OKLab(L: fillL, a: fillChroma * cos(hueRad), b: fillChroma * sin(hueRad))
    let (r, g, b) = oklabToRGB(lab)
    // effective on-screen color after ghostty 0.85 alpha over black@0.5 card over floor
    print(String(format: "L=%.3f -> %@", fillL, hex(r, g, b)))
}
