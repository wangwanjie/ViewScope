import Foundation

enum ViewScopeInterfaceLanguage: String {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    init(identifier: String?) {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            self = .english
            return
        }

        let normalized = identifier.lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
            self = .traditionalChinese
        } else if normalized.hasPrefix("zh") {
            self = .simplifiedChinese
        } else {
            self = .english
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        text(key, arguments: arguments)
    }

    func text(_ key: String, arguments: [CVarArg]) -> String {
        let format = Self.table[self]?[key] ?? Self.table[.english]?[key] ?? key
        guard arguments.isEmpty == false else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static let table: [ViewScopeInterfaceLanguage: [String: String]] = [
        .english: [
            "server.error.selected_node_gone": "The selected node is no longer available. Refresh the capture and try again.",
            "server.section.identity": "Identity",
            "server.section.state": "State",
            "server.section.geometry": "Geometry",
            "server.section.layout": "Layout",
            "server.section.rendering": "Rendering",
            "server.section.control": "Control",
            "server.item.class": "Class",
            "server.item.title": "Title",
            "server.item.window_number": "Window Number",
            "server.item.address": "Address",
            "server.item.visible": "Visible",
            "server.item.key": "Key",
            "server.item.main": "Main",
            "server.item.level": "Level",
            "server.item.frame": "Frame",
            "server.item.content_layout": "Content Layout",
            "server.item.bounds": "Bounds",
            "server.item.intrinsic_size": "Intrinsic Size",
            "server.item.translates_mask": "Translates Mask",
            "server.item.hugging_h": "Hugging H",
            "server.item.hugging_v": "Hugging V",
            "server.item.compression_h": "Compression H",
            "server.item.compression_v": "Compression V",
            "server.item.hidden": "Hidden",
            "server.item.alpha": "Alpha",
            "server.item.layer_backed": "Layer Backed",
            "server.item.flipped": "Flipped",
            "server.item.subviews": "Subviews",
            "server.item.background": "Background",
            "server.item.enabled": "Enabled",
            "server.item.value": "Value",
            "server.item.identifier": "Identifier",
            "server.item.tooltip": "Tool Tip",
            "server.value.no_intrinsic_size": "No intrinsic size",
            "server.value.yes": "Yes",
            "server.value.no": "No",
            "server.value.no_active_constraints": "No active constraints on the selected node.",
            "server.value.window_fallback": "Window",
            "server.value.outline_view": "OutlineView",
            "server.value.table_view": "TableView",
            "server.value.row_format": "Row %d",
            "server.subtitle.visible_rows": "%d visible rows",
            "server.subtitle.rows_cols": "%1$d rows • %2$d cols",
            "server.subtitle.tabs": "%d tabs",
            "server.value.image": "Image",
            "server.subtitle.arranged": "%d arranged",
            "server.value.scrollable": "Scrollable",
        ],
        .simplifiedChinese: [
            "server.error.selected_node_gone": "选中的节点已不存在，请刷新采集后重试。",
            "server.section.identity": "标识",
            "server.section.state": "状态",
            "server.section.geometry": "几何",
            "server.section.layout": "布局",
            "server.section.rendering": "渲染",
            "server.section.control": "控件",
            "server.item.class": "类名",
            "server.item.title": "标题",
            "server.item.window_number": "窗口编号",
            "server.item.address": "地址",
            "server.item.visible": "可见",
            "server.item.key": "Key 窗口",
            "server.item.main": "Main 窗口",
            "server.item.level": "层级",
            "server.item.frame": "Frame",
            "server.item.content_layout": "内容布局",
            "server.item.bounds": "Bounds",
            "server.item.intrinsic_size": "固有尺寸",
            "server.item.translates_mask": "Translates Mask",
            "server.item.hugging_h": "水平 Hugging",
            "server.item.hugging_v": "垂直 Hugging",
            "server.item.compression_h": "水平压缩抗性",
            "server.item.compression_v": "垂直压缩抗性",
            "server.item.hidden": "隐藏",
            "server.item.alpha": "透明度",
            "server.item.layer_backed": "Layer Backed",
            "server.item.flipped": "坐标翻转",
            "server.item.subviews": "子视图数",
            "server.item.background": "背景色",
            "server.item.enabled": "可用",
            "server.item.value": "值",
            "server.item.identifier": "标识符",
            "server.item.tooltip": "提示文本",
            "server.value.no_intrinsic_size": "无固有尺寸",
            "server.value.yes": "是",
            "server.value.no": "否",
            "server.value.no_active_constraints": "当前选中节点没有生效中的约束。",
            "server.value.window_fallback": "窗口",
            "server.value.outline_view": "大纲视图",
            "server.value.table_view": "表格视图",
            "server.value.row_format": "第 %d 行",
            "server.subtitle.visible_rows": "%d 个可见行",
            "server.subtitle.rows_cols": "%1$d 行 • %2$d 列",
            "server.subtitle.tabs": "%d 个标签",
            "server.value.image": "图像",
            "server.subtitle.arranged": "%d 个 arranged 子视图",
            "server.value.scrollable": "可滚动",
        ],
        .traditionalChinese: [
            "server.error.selected_node_gone": "選取的節點已不存在，請重新整理擷取後再試一次。",
            "server.section.identity": "識別",
            "server.section.state": "狀態",
            "server.section.geometry": "幾何",
            "server.section.layout": "版面配置",
            "server.section.rendering": "渲染",
            "server.section.control": "控制項",
            "server.item.class": "類別",
            "server.item.title": "標題",
            "server.item.window_number": "視窗編號",
            "server.item.address": "位址",
            "server.item.visible": "可見",
            "server.item.key": "Key 視窗",
            "server.item.main": "Main 視窗",
            "server.item.level": "層級",
            "server.item.frame": "Frame",
            "server.item.content_layout": "內容版面",
            "server.item.bounds": "Bounds",
            "server.item.intrinsic_size": "內在尺寸",
            "server.item.translates_mask": "Translates Mask",
            "server.item.hugging_h": "水平 Hugging",
            "server.item.hugging_v": "垂直 Hugging",
            "server.item.compression_h": "水平抗壓縮",
            "server.item.compression_v": "垂直抗壓縮",
            "server.item.hidden": "隱藏",
            "server.item.alpha": "透明度",
            "server.item.layer_backed": "Layer Backed",
            "server.item.flipped": "座標翻轉",
            "server.item.subviews": "子視圖數",
            "server.item.background": "背景色",
            "server.item.enabled": "啟用",
            "server.item.value": "值",
            "server.item.identifier": "識別碼",
            "server.item.tooltip": "提示文字",
            "server.value.no_intrinsic_size": "無內在尺寸",
            "server.value.yes": "是",
            "server.value.no": "否",
            "server.value.no_active_constraints": "目前選取的節點沒有作用中的約束。",
            "server.value.window_fallback": "視窗",
            "server.value.outline_view": "大綱視圖",
            "server.value.table_view": "表格視圖",
            "server.value.row_format": "第 %d 列",
            "server.subtitle.visible_rows": "%d 個可見列",
            "server.subtitle.rows_cols": "%1$d 列 • %2$d 欄",
            "server.subtitle.tabs": "%d 個分頁",
            "server.value.image": "影像",
            "server.subtitle.arranged": "%d 個 arranged 子視圖",
            "server.value.scrollable": "可捲動",
        ],
    ]
}
