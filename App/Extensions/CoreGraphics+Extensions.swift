import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension CGImage {
    func pngData() -> Data? {
        let mutableData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                mutableData, UTType.png.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                mutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, self, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }
}
