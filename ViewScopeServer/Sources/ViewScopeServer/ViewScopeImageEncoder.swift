import AppKit

@MainActor
struct ViewScopeImageEncoder {
    func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func base64PNG(for image: NSImage) -> String? {
        pngData(for: image)?.base64EncodedString()
    }
}
