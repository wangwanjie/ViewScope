#if os(iOS)
import UIKit

/// UIKit 版 PNG 编码器：直接使用 `UIImage.pngData()`，不绕道 TIFF。
@MainActor
struct ViewScopeImageEncoder {
    func pngData(for image: UIImage) -> Data? {
        image.pngData()
    }

    func base64PNG(for image: UIImage) -> String? {
        pngData(for: image)?.base64EncodedString()
    }
}
#endif
