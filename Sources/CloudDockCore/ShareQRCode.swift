import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ShareQRCode {
    public static func png(address: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { throw CloudError.message("地址过长，无法生成二维码。请复制分享地址。") }
        let scale = 8
        let extent = code.extent.integral
        let pixels = Int(extent.width) * scale
        let margin = 4 * scale
        let size = pixels + margin * 2
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(code, from: extent),
              let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CloudError.message("二维码生成失败，可以复制分享地址继续分享。")
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))
        canvas.interpolationQuality = .none
        canvas.draw(image, in: CGRect(x: margin, y: margin, width: pixels, height: pixels))
        let data = NSMutableData()
        guard let rendered = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CloudError.message("无法导出二维码图片。")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw CloudError.message("无法导出二维码图片。") }
        return data as Data
    }
}
