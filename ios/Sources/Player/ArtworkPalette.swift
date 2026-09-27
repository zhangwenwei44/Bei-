import SwiftUI
import UIKit

struct ArtworkPalette: Equatable {
    var light: Color
    var main: Color
    var dark: Color
    var near: Color

    var scrim: Color { near }

    var gradient: [Color] { [light, main, dark, near] }
}

enum ArtworkPaletteEngine {

    private static let sampleSide = 32
    private static let hueBins = 24
    private static let minLuminance: Double = 0.12
    private static let maxLuminance: Double = 0.92

    /// 从封面图取色；图不可用时回退到歌名/歌手哈希色板。
    static func palette(for image: UIImage?, seed: String) -> ArtworkPalette {
        guard let image, let base = dominantColor(of: image) else {
            return hashed(seed: seed)
        }
        return derived(from: base)
    }

    // MARK: - 采样

    private static func dominantColor(of image: UIImage) -> LabColor? {
        guard let pixels = downsample(image, side: sampleSide) else { return nil }

        var counts = [Double](repeating: 0, count: hueBins)
        var sums = [LabColor](repeating: LabColor(L: 0, C: 0, h: 0), count: hueBins)

        for pixel in pixels {
            let lum = relativeLuminance(pixel)
            guard lum >= minLuminance, lum <= maxLuminance else { continue }
            let lab = LabColor(rgb: pixel)
            guard lab.C > 0.02 else { continue }
            let bin = hueIndex(lab.h)
            counts[bin] += 1
            sums[bin].L += lab.L
            sums[bin].C += lab.C
            sums[bin].h += lab.h
        }

        guard let peak = counts.indices.max(by: { counts[$0] < counts[$1] }),
              counts[peak] > 0 else { return nil }

        var weightTotal: Double = 0
        var base = LabColor(L: 0, C: 0, h: 0)
        for offset in -1...1 {
            let bin = ((peak + offset) % hueBins + hueBins) % hueBins
            guard counts[bin] > 0 else { continue }
            let weight = counts[bin]
            let avg = LabColor(L: sums[bin].L / weight, C: sums[bin].C / weight, h: sums[bin].h / weight)
            base.L += avg.L * weight
            base.C += avg.C * weight
            base.h += LabColor.normalizedHue(avg.h) * weight
            weightTotal += weight
        }
        base.L /= weightTotal
        base.C /= weightTotal
        base.h /= weightTotal
        return base
    }

    private static func downsample(_ image: UIImage, side: Int) -> [SIMD3<Double>]? {
        guard let cgImage = image.cgImage else { return nil }
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)
        guard let context = CGContext(data: &buffer,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var result: [SIMD3<Double>] = []
        result.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                let offset = y * bytesPerRow + x * 4
                guard buffer[offset + 3] > 8 else { continue }
                result.append(SIMD3(Double(buffer[offset]) / 255,
                                    Double(buffer[offset + 1]) / 255,
                                    Double(buffer[offset + 2]) / 255))
            }
        }
        return result
    }

    private static func relativeLuminance(_ rgb: SIMD3<Double>) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.x) + 0.7152 * linear(rgb.y) + 0.0722 * linear(rgb.z)
    }

    private static func hueIndex(_ degrees: Double) -> Int {
        let normalized = LabColor.normalizedHue(degrees) / 360
        return min(hueBins - 1, max(0, Int(normalized * Double(hueBins))))
    }

    // MARK: - 派生

    /// L 夹到 0.22 – 0.55、C 夹到 ≤ 0.19，再派生亮/主/暗/近黑四段。
    private static func derived(from base: LabColor) -> ArtworkPalette {
        let L = min(0.55, max(0.22, base.L))
        let C = min(0.19, base.C)
        let h = base.h
        return ArtworkPalette(
            light: Color(lab: LabColor(L: min(0.68, L + 0.16), C: C * 0.8, h: h + 25)),
            main: Color(lab: LabColor(L: L, C: C, h: h)),
            dark: Color(lab: LabColor(L: max(0.14, L - 0.14), C: C * 1.05, h: h)),
            near: Color(lab: LabColor(L: max(0.10, L - 0.24), C: C * 0.9, h: h + 180))
        )
    }

    private static func hashed(seed: String) -> ArtworkPalette {
        var hash: UInt64 = 5381
        for byte in Array(seed.utf8) { hash = (hash &* 33) &+ UInt64(byte) }
        let base = LabColor(L: 0.34, C: 0.14, h: Double(hash % 360))
        return derived(from: base)
    }
}

// MARK: - OKLab

struct LabColor {
    var L: Double
    var C: Double
    var h: Double

    static func normalizedHue(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    init(L: Double, C: Double, h: Double) {
        self.L = L
        self.C = C
        self.h = LabColor.normalizedHue(h)
    }

    init(rgb: SIMD3<Double>) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb.x), g = linear(rgb.y), b = linear(rgb.z)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)

        self.L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        self.C = (a * a + bb * bb).squareRoot()
        self.h = LabColor.normalizedHue(atan2(bb, a) * 180 / .pi)
    }

    var rgb: SIMD3<Double> {
        let radians = h * .pi / 180
        let a = C * cos(radians)
        let b = C * sin(radians)

        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b

        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_

        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        func encode(_ c: Double) -> Double {
            let clamped = min(1, max(0, c))
            let value = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return min(1, max(0, value))
        }
        return SIMD3(encode(r), encode(g), encode(bb))
    }
}

extension Color {
    init(lab: LabColor) {
        let rgb = lab.rgb
        self.init(.sRGB,
                  red: rgb.x,
                  green: rgb.y,
                  blue: rgb.z,
                  opacity: 1)
    }
}
