import AppKit
import SceneKit

enum PreviewLayeredSceneConstants {
    static let unitScale: CGFloat = 0.01
    static let defaultPitch: CGFloat = (-10 * .pi) / 180
    static let defaultYaw: CGFloat = 0.6 // ≈34°
    static let selectableCategoryMask = 1 << 1
    static let minimumZoom: CGFloat = 0.35
    static let maximumZoom: CGFloat = 4
    static let flatDepthStep: CGFloat = 0.01
    static let sameZIndexBiasStep: CGFloat = 0.0001
    static let maskNodeZOffset: CGFloat = 0.001
    static let borderNodeZOffset: CGFloat = 0.002
    static let selectionOverlayZOffset: CGFloat = 0.01
    /// zoom=1 时画布内容占视图的比例（0-1），可调整。
    static let defaultFillRatio: CGFloat = 0.7
    static let cameraSensorWidth: CGFloat = 36 // SceneKit 默认
    static let cameraDistance: CGFloat = 34

    static func translationFactor(for zoomScale: CGFloat) -> CGFloat {
        let normalizedZoom = (min(max(zoomScale, minimumZoom), maximumZoom) - minimumZoom) / (maximumZoom - minimumZoom)
        return (1 - normalizedZoom) * 0.7 + 0.3
    }
}

final class PreviewLayeredDisplayNode {
    let node = SCNNode()

    private let contentPlane = SCNPlane(width: 1, height: 1)
    private let contentNode = SCNNode()
    private let maskPlane = SCNPlane(width: 1, height: 1)
    private let maskNode = SCNNode()
    private let borderNode = SCNNode()
    private var item: PreviewLayeredScenePlan.Item?

    var zPosition: CGFloat {
        CGFloat(node.position.z)
    }

    init() {
        contentPlane.firstMaterial?.isDoubleSided = true
        contentPlane.firstMaterial?.lightingModel = .constant
        contentPlane.firstMaterial?.diffuse.contents = NSColor.clear
        contentPlane.firstMaterial?.diffuse.wrapS = .clamp
        contentPlane.firstMaterial?.diffuse.wrapT = .clamp
        contentNode.geometry = contentPlane
        node.addChildNode(contentNode)

        maskPlane.firstMaterial?.isDoubleSided = true
        maskPlane.firstMaterial?.lightingModel = .constant
        maskPlane.firstMaterial?.diffuse.contents = NSColor.clear
        maskPlane.firstMaterial?.transparency = 0
        maskPlane.firstMaterial?.writesToDepthBuffer = false
        maskPlane.firstMaterial?.readsFromDepthBuffer = false
        maskNode.geometry = maskPlane
        maskNode.position.z = PreviewLayeredSceneConstants.maskNodeZOffset
        node.addChildNode(maskNode)

        borderNode.position.z = PreviewLayeredSceneConstants.borderNodeZOffset
        node.addChildNode(borderNode)
    }

    func configure(
        item: PreviewLayeredScenePlan.Item,
        textureImage: NSImage,
        canvasSize: CGSize,
        unitScale: CGFloat,
        centeredZIndex: CGFloat,
        zStep: CGFloat,
        zBias: CGFloat,
        showsBorder: Bool,
        selectableCategoryMask: Int
    ) {
        // 一个 scene item 对应一个真正可见的 SceneKit 平面节点。
        // 几何位置来自 scene plan，纹理则从根截图裁切。
        self.item = item
        node.name = "display-\(item.nodeID)"
        contentNode.name = item.nodeID
        contentNode.categoryBitMask = selectableCategoryMask
        contentNode.renderingOrder = item.displayOrder * 10
        maskNode.renderingOrder = item.displayOrder * 10 + 1
        borderNode.renderingOrder = item.displayOrder * 10 + 2

        let width = max(item.displayRect.width * unitScale, 0.001)
        let height = max(item.displayRect.height * unitScale, 0.001)
        contentPlane.width = width
        contentPlane.height = height
        maskPlane.width = width
        maskPlane.height = height

        contentPlane.firstMaterial?.diffuse.contents = textureImage

        node.position = SCNVector3(
            Float((item.displayRect.midX - (canvasSize.width / 2)) * unitScale),
            Float(((canvasSize.height / 2) - item.displayRect.midY) * unitScale),
            Float(centeredZIndex * zStep + zBias)
        )

        updateAppearance(isSelected: false, isFocused: false, showsBorder: showsBorder)
    }

    func updateAppearance(isSelected: Bool, isFocused: Bool, showsBorder: Bool) {
        guard let item else { return }
        contentNode.opacity = item.displayingIndependently ? 1 : 0
        contentNode.categoryBitMask = item.displayingIndependently
            ? PreviewLayeredSceneConstants.selectableCategoryMask
            : 0

        if isSelected {
            maskNode.isHidden = false
            maskPlane.firstMaterial?.diffuse.contents = NSColor.systemBlue
            maskNode.opacity = 0.35
        } else if isFocused {
            maskNode.isHidden = false
            maskPlane.firstMaterial?.diffuse.contents = NSColor.systemBlue
            maskNode.opacity = 0.18
        } else {
            maskNode.isHidden = true
            maskNode.opacity = 0
        }

        if item.displayingIndependently && (showsBorder || isSelected || isFocused) {
            borderNode.isHidden = false
            borderNode.geometry = PreviewLayeredSceneSnapshotFactory.makeBorderGeometry(
                size: item.displayRect.size,
                unitScale: PreviewLayeredSceneConstants.unitScale,
                color: isSelected
                    ? NSColor.systemBlue
                    : NSColor.systemBlue.withAlphaComponent(isFocused ? 0.55 : 0.22)
            )
        } else {
            borderNode.isHidden = true
            borderNode.geometry = nil
        }
    }
}

enum PreviewLayeredSceneSnapshotFactory {
    static func makeTextureImage(
        for item: PreviewLayeredScenePlan.Item,
        rootImage: NSImage,
        canvasSize: CGSize
    ) -> NSImage {
        makeItemImage(
            for: item,
            rootImage: rootImage,
            canvasSize: canvasSize
        )
    }

    static func makeTextureImage(fromSourceImage image: NSImage, size: CGSize) -> NSImage {
        makeSceneTextureImage(
            fromTopLeftImage: makeTopLeftWorkingImage(from: image, size: size),
            size: size
        )
    }

    static func makeTransparentTopLeftImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    static func makeItemImage(
        for item: PreviewLayeredScenePlan.Item,
        rootImage: NSImage,
        canvasSize: CGSize
    ) -> NSImage {
        // 这里是 3D 纹理裁切的关键边界：
        // - `item.displayRect` 仍保持数据源 top-left 语义，供 scene 布局使用
        // - 纹理裁切与 punch-out 都统一在 top-left 语义下完成，和 2D layered 画布保持一致
        let targetSize = item.displayRect.size
        guard targetSize.width > 0,
              targetSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        let bounds = CGRect(origin: .zero, size: targetSize)
        let topLeftImage = NSImage(size: targetSize)
        topLeftImage.lockFocusFlipped(true)
        NSColor.clear.setFill()
        bounds.fill()

        let clipPath = NSBezierPath(rect: bounds)
        for punchedOutRect in item.punchedOutRects {
            // punch-out 使用 item 自己的局部纹理坐标；
            // 清掉后该区域的内容交给更前面的图层自己显示。
            let localRect = punchedOutRect
                .offsetBy(dx: -item.displayRect.minX, dy: -item.displayRect.minY)
                .intersection(bounds)
            guard localRect.isNull == false, localRect.isEmpty == false else {
                continue
            }
            clipPath.append(NSBezierPath(rect: localRect))
        }
        clipPath.windingRule = .evenOdd
        clipPath.addClip()

        let drawRect = CGRect(
            x: -item.displayRect.minX,
            y: -item.displayRect.minY,
            width: canvasSize.width,
            height: canvasSize.height
        )
        rootImage.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        topLeftImage.unlockFocus()

        return makeSceneTextureImage(fromTopLeftImage: topLeftImage, size: targetSize)
    }

    static func makeTopLeftWorkingImage(from image: NSImage, size: CGSize) -> NSImage {
        guard size.width > 0,
              size.height > 0 else {
            return image
        }

        let normalizedImage = NSImage(size: size)
        normalizedImage.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.draw(
            in: CGRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        normalizedImage.unlockFocus()
        return normalizedImage
    }

    private static func makeSceneTextureImage(fromTopLeftImage image: NSImage, size: CGSize) -> NSImage {
        // 输入已经是正确的 top-left 方向图像（由 makeTopLeftWorkingImage 归一化），
        // SceneKit 的 SCNMaterial 接受 NSImage 时会自行处理坐标映射，无需额外翻转。
        return image
    }

    static func makeBorderGeometry(size: CGSize, unitScale: CGFloat, color: NSColor) -> SCNGeometry {
        let halfWidth = Float(size.width * unitScale * 0.5)
        let halfHeight = Float(size.height * unitScale * 0.5)
        let vertices = [
            SCNVector3(-halfWidth, halfHeight, 0),
            SCNVector3(halfWidth, halfHeight, 0),
            SCNVector3(halfWidth, -halfHeight, 0),
            SCNVector3(-halfWidth, -halfHeight, 0)
        ]
        let indices: [UInt8] = [0, 1, 1, 2, 2, 3, 3, 0]

        let source = SCNGeometrySource(vertices: vertices)
        let data = Data(indices)
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: 4,
            bytesPerIndex: MemoryLayout<UInt8>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.readsFromDepthBuffer = false
        geometry.firstMaterial?.writesToDepthBuffer = false
        return geometry
    }
}
