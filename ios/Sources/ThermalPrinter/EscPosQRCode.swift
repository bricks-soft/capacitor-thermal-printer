import CoreGraphics
import CoreImage
import Foundation

enum EscPosQRCode {
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    static func matrix(for data: String) throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw EscPosError.barcode("Unable to encode QR code")
        }
        filter.setValue(Data(data.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent)
        else {
            throw EscPosError.barcode("Unable to encode QR code")
        }
        let width = image.width
        let height = image.height
        var gray = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = gray.withUnsafeMutableBytes { raw in
            guard let bitmap = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            bitmap.interpolationQuality = .none
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw EscPosError.barcode("Unable to encode QR code")
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where gray[y * width + x] < 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            throw EscPosError.barcode("Unable to encode QR code")
        }
        let size = max(maxX - minX, maxY - minY) + 1
        var modules = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
        for row in 0..<size {
            for column in 0..<size {
                let x = minX + column
                let y = minY + row
                if x < width && y < height {
                    modules[row][column] = gray[y * width + x] < 128
                }
            }
        }
        return modules
    }
}
