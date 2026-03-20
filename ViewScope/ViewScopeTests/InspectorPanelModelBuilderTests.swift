import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct InspectorPanelModelBuilderTests {
    @Test func builderShowsEditableRowsForCurrentWhitelistedProperties() async throws {
        let capture = SampleFixture.capture()
        let node = try #require(capture.nodes["window-0-view-1-2"])
        let detail = makeDetail(
            nodeID: node.id,
            host: capture.host,
            sections: [
                ViewScopePropertySection(title: "Layout", items: [
                    ViewScopePropertyItem(title: "Frame", value: "x 10 y 20 w 300 h 200"),
                    ViewScopePropertyItem(title: "X", value: "10.0", editable: .number(key: "frame.x", value: 10)),
                    ViewScopePropertyItem(title: "Y", value: "20.0", editable: .number(key: "frame.y", value: 20)),
                    ViewScopePropertyItem(title: "Width", value: "300.0", editable: .number(key: "frame.width", value: 300)),
                    ViewScopePropertyItem(title: "Height", value: "200.0", editable: .number(key: "frame.height", value: 200)),
                    ViewScopePropertyItem(title: "Bounds", value: "x 0 y 0 w 300 h 200"),
                    ViewScopePropertyItem(title: "Bounds X", value: "0.0", editable: .number(key: "bounds.x", value: 0)),
                    ViewScopePropertyItem(title: "Bounds Y", value: "0.0", editable: .number(key: "bounds.y", value: 0)),
                    ViewScopePropertyItem(title: "Bounds Width", value: "300.0", editable: .number(key: "bounds.width", value: 300)),
                    ViewScopePropertyItem(title: "Bounds Height", value: "200.0", editable: .number(key: "bounds.height", value: 200)),
                    ViewScopePropertyItem(title: "Content Insets", value: "{1, 2, 3, 4}"),
                    ViewScopePropertyItem(title: "Inset Top", value: "1.0", editable: .number(key: "contentInsets.top", value: 1)),
                    ViewScopePropertyItem(title: "Inset Left", value: "2.0", editable: .number(key: "contentInsets.left", value: 2)),
                    ViewScopePropertyItem(title: "Inset Bottom", value: "3.0", editable: .number(key: "contentInsets.bottom", value: 3)),
                    ViewScopePropertyItem(title: "Inset Right", value: "4.0", editable: .number(key: "contentInsets.right", value: 4))
                ]),
                ViewScopePropertySection(title: "Rendering", items: [
                    ViewScopePropertyItem(title: "Hidden", value: "No", editable: .toggle(key: "hidden", value: false)),
                    ViewScopePropertyItem(title: "Alpha", value: "0.80", editable: .number(key: "alpha", value: 0.8)),
                    ViewScopePropertyItem(title: "Background", value: "#112233FF", editable: .text(key: "backgroundColor", value: "#112233FF"))
                ]),
                ViewScopePropertySection(title: "Control", items: [
                    ViewScopePropertyItem(title: "Value", value: "Hello", editable: .text(key: "control.value", value: "Hello"))
                ])
            ]
        )

        let model = InspectorPanelModelBuilder().makeModel(capture: capture, node: node, detail: detail)

        #expect(containsToggleRow(withKey: "hidden", in: model))
        #expect(containsNumberRow(withKey: "alpha", in: model))
        #expect(containsColorRow(withKey: "backgroundColor", in: model))
        #expect(containsTextRow(withKey: "control.value", in: model))
        #expect(containsQuadRow(withKeys: ["frame.x", "frame.y", "frame.width", "frame.height"], in: model))
        #expect(containsQuadRow(withKeys: ["bounds.x", "bounds.y", "bounds.width", "bounds.height"], in: model))
        #expect(containsQuadRow(withKeys: ["contentInsets.top", "contentInsets.left", "contentInsets.bottom", "contentInsets.right"], in: model))
    }

    @Test func builderKeepsUnknownOrReadOnlyItemsVisibleAsReadOnlyRows() async throws {
        let capture = SampleFixture.capture()
        let node = try #require(capture.nodes["window-0-view-1-2"])
        let detail = makeDetail(
            nodeID: node.id,
            host: capture.host,
            sections: [
                ViewScopePropertySection(title: "Identity", items: [
                    ViewScopePropertyItem(title: "Unknown Metric", value: "42"),
                    ViewScopePropertyItem(title: "Layer Backed", value: "Yes")
                ])
            ]
        )

        let model = InspectorPanelModelBuilder().makeModel(capture: capture, node: node, detail: detail)

        #expect(containsReadOnlyRow(title: "Unknown Metric", value: "42", in: model))
        #expect(containsReadOnlyRow(title: "Layer Backed", value: "Yes", in: model))
    }

    @Test func builderShowsNewLowRiskEditableRows() async throws {
        let capture = SampleFixture.capture()
        let node = try #require(capture.nodes["window-0-view-1-1"])
        let detail = makeDetail(
            nodeID: node.id,
            host: capture.host,
            sections: [
                ViewScopePropertySection(title: "Identity", items: [
                    ViewScopePropertyItem(title: "Tool Tip", value: "Inspect this", editable: .text(key: "toolTip", value: "Inspect this"))
                ]),
                ViewScopePropertySection(title: "Rendering", items: [
                    ViewScopePropertyItem(title: "Corner Radius", value: "12.0", editable: .number(key: "layer.cornerRadius", value: 12)),
                    ViewScopePropertyItem(title: "Border Width", value: "2.0", editable: .number(key: "layer.borderWidth", value: 2))
                ]),
                ViewScopePropertySection(title: "Control", items: [
                    ViewScopePropertyItem(title: "Enabled", value: "Yes", editable: .toggle(key: "enabled", value: true)),
                    ViewScopePropertyItem(title: "Button State", value: "On", editable: .toggle(key: "button.state", value: true)),
                    ViewScopePropertyItem(title: "Placeholder", value: "Type here", editable: .text(key: "textField.placeholderString", value: "Type here"))
                ])
            ]
        )

        let model = InspectorPanelModelBuilder().makeModel(capture: capture, node: node, detail: detail)

        #expect(containsTextRow(withKey: "toolTip", in: model))
        #expect(containsToggleRow(withKey: "enabled", in: model))
        #expect(containsToggleRow(withKey: "button.state", in: model))
        #expect(containsTextRow(withKey: "textField.placeholderString", in: model))
        #expect(containsNumberRow(withKey: "layer.cornerRadius", in: model))
        #expect(containsNumberRow(withKey: "layer.borderWidth", in: model))
    }

    private func makeDetail(
        nodeID: String,
        host: ViewScopeHostInfo,
        sections: [ViewScopePropertySection]
    ) -> ViewScopeNodeDetailPayload {
        ViewScopeNodeDetailPayload(
            nodeID: nodeID,
            host: host,
            sections: sections,
            constraints: [],
            ancestry: ["Fixture", nodeID],
            screenshotPNGBase64: nil,
            screenshotSize: .zero,
            highlightedRect: .zero
        )
    }

    private func containsTextRow(withKey key: String, in model: InspectorPanelModel) -> Bool {
        model.sections.contains { section in
            section.rows.contains {
                if case .text(let textModel) = $0 {
                    return textModel.property.key == key
                }
                return false
            }
        }
    }

    private func containsToggleRow(withKey key: String, in model: InspectorPanelModel) -> Bool {
        model.sections.contains { section in
            section.rows.contains {
                if case .toggle(let toggleModel) = $0 {
                    return toggleModel.property.key == key
                }
                return false
            }
        }
    }

    private func containsNumberRow(withKey key: String, in model: InspectorPanelModel) -> Bool {
        model.sections.contains { section in
            section.rows.contains {
                if case .number(let numberModel) = $0 {
                    return numberModel.property.key == key
                }
                return false
            }
        }
    }

    private func containsColorRow(withKey key: String, in model: InspectorPanelModel) -> Bool {
        model.sections.contains { section in
            section.rows.contains {
                if case .color(let colorModel) = $0 {
                    return colorModel.property.key == key
                }
                return false
            }
        }
    }

    private func containsQuadRow(withKeys keys: [String], in model: InspectorPanelModel) -> Bool {
        let expectedKeys = Set(keys)
        return model.sections.contains { section in
            section.rows.contains {
                if case .quad(let quadModel) = $0 {
                    return Set(quadModel.fields.map(\.property.key)) == expectedKeys
                }
                return false
            }
        }
    }

    private func containsReadOnlyRow(title: String, value: String, in model: InspectorPanelModel) -> Bool {
        model.sections.contains { section in
            section.rows.contains {
                if case .readOnly(let rowTitle, let rowValue) = $0 {
                    return rowTitle == title && rowValue == value
                }
                return false
            }
        }
    }
}
