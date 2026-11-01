import CoreGraphics
import Foundation
import ImageIO

struct EscPosBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt32]

    init(width: Int, height: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        pixels[y * width + x]
    }

    static func decode(_ data: Data) -> EscPosBitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            return nil
        }
        return EscPosBitmap(image: image)
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let isGray = image.colorSpace?.model == .monochrome
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            hasAlpha = false
        default:
            hasAlpha = true
        }
        if isGray && !hasAlpha, let gray = EscPosBitmap.renderGray(image) {
            self.init(width: width, height: height, pixels: gray.map { value in
                let level = UInt32(value)
                return 0xFF00_0000 | level << 16 | level << 8 | level
            })
            return
        }
        guard let rgba = EscPosBitmap.renderRGBA(image, width: width, height: height) else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let alpha = UInt32(rgba[index * 4 + 3])
            var red = UInt32(rgba[index * 4])
            var green = UInt32(rgba[index * 4 + 1])
            var blue = UInt32(rgba[index * 4 + 2])
            if alpha == 0 {
                red = 0
                green = 0
                blue = 0
            } else if alpha < 255 {
                red = min(255, (red * 255 + alpha / 2) / alpha)
                green = min(255, (green * 255 + alpha / 2) / alpha)
                blue = min(255, (blue * 255 + alpha / 2) / alpha)
            }
            pixels[index] = alpha << 24 | red << 16 | green << 8 | blue
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    func scaled(width newWidth: Int, height newHeight: Int) -> EscPosBitmap {
        guard newWidth > 0, newHeight > 0, let image = cgImage() else {
            return EscPosBitmap(width: max(newWidth, 0), height: max(newHeight, 0), pixels: [UInt32](repeating: 0, count: max(newWidth, 0) * max(newHeight, 0)))
        }
        let bytesPerRow = newWidth * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * newHeight)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            return true
        }
        guard drawn, let scaledImage = EscPosBitmap.makeImage(rgba: buffer, width: newWidth, height: newHeight),
              let result = EscPosBitmap(image: scaledImage)
        else {
            return EscPosBitmap(width: newWidth, height: newHeight, pixels: [UInt32](repeating: 0, count: newWidth * newHeight))
        }
        return result
    }

    private func cgImage() -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let pixel = pixels[index]
            let alpha = (pixel >> 24) & 0xFF
            rgba[index * 4] = UInt8((((pixel >> 16) & 0xFF) * alpha + 127) / 255)
            rgba[index * 4 + 1] = UInt8((((pixel >> 8) & 0xFF) * alpha + 127) / 255)
            rgba[index * 4 + 2] = UInt8(((pixel & 0xFF) * alpha + 127) / 255)
            rgba[index * 4 + 3] = UInt8(alpha)
        }
        return EscPosBitmap.makeImage(rgba: rgba, width: width, height: height)
    }

    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func renderRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let space: CGColorSpace
        if let imageSpace = image.colorSpace, imageSpace.model == .rgb {
            space = imageSpace
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }

    private static func renderGray(_ image: CGImage) -> [UInt8]? {
        guard let space = image.colorSpace else { return nil }
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }
}
