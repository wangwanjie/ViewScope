import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct InspectorPropertyCommitCoordinatorTests {
    @Test func numberCommitRejectsInvalidLocalizedInputAndRequestsReset() async throws {
        let rowView = InspectorCommitRowSpy()
        var didBeep = false
        var receivedMutation: ViewScopeEditableProperty?
        let coordinator = InspectorPropertyCommitCoordinator(
            locale: Locale(identifier: "fr_FR"),
            beep: { didBeep = true },
            applyMutation: { request in
                receivedMutation = request.property
                return true
            }
        )

        await coordinator.commitNumber(
            "1 234,5.6",
            property: .number(key: "alpha", value: 0.8),
            rowView: rowView,
            nodeID: "node-1"
        )

        #expect(didBeep)
        #expect(receivedMutation == nil)
        #expect(rowView.resetDisplayedValueCallCount == 1)
        #expect(rowView.editingEnabledStates.isEmpty)
    }

    @Test func colorCommitUppercasesHexBeforeMutation() async throws {
        let rowView = InspectorCommitRowSpy()
        var receivedMutation: ViewScopeEditableProperty?
        let coordinator = InspectorPropertyCommitCoordinator(
            locale: Locale(identifier: "en_US_POSIX"),
            applyMutation: { request in
                receivedMutation = request.property
                return true
            }
        )

        await coordinator.commitColor(
            "#aa11ccff",
            property: .text(key: "backgroundColor", value: "#000000FF"),
            rowView: rowView,
            nodeID: "node-1"
        )

        #expect(receivedMutation == .text(key: "backgroundColor", value: "#AA11CCFF"))
        #expect(rowView.resetDisplayedValueCallCount == 0)
        #expect(rowView.editingEnabledStates == [false, true])
    }

    @Test func failedMutationReenablesEditingAndRestoresOriginalValue() async throws {
        let rowView = InspectorCommitRowSpy()
        let coordinator = InspectorPropertyCommitCoordinator(
            locale: Locale(identifier: "en_US_POSIX"),
            applyMutation: { _ in false }
        )

        await coordinator.commitText(
            "Updated",
            property: .text(key: "toolTip", value: "Original"),
            rowView: rowView,
            nodeID: "node-1"
        )

        #expect(rowView.editingEnabledStates == [false, true])
        #expect(rowView.resetDisplayedValueCallCount == 1)
    }
}

extension InspectorPropertyCommitCoordinatorTests {
    @Test func unchangedValuesAreNotCommitted() async throws {
        let rowView = InspectorCommitRowSpy()
        var requests: [InspectorMutationRequest] = []
        let coordinator = InspectorPropertyCommitCoordinator(
            locale: Locale(identifier: "en_US_POSIX"),
            applyMutation: { request in
                requests.append(request)
                return true
            }
        )

        await coordinator.commitNumber("12", property: .number(key: "frame.x", value: 12), rowView: rowView, nodeID: "node-1")
        await coordinator.commitText("Same", property: .text(key: "toolTip", value: "Same"), rowView: rowView, nodeID: "node-1")
        await coordinator.commitToggle(true, property: .toggle(key: "hidden", value: true), rowView: rowView, nodeID: "node-1")
        await coordinator.commitColor("#aabbccff", property: .text(key: "backgroundColor", value: "#AABBCCFF"), rowView: rowView, nodeID: "node-1")
        await coordinator.commitEnumeration(2, property: .enumeration(key: "k", value: 2, options: []), rowView: rowView, nodeID: "node-1")

        #expect(requests.isEmpty)
        #expect(rowView.editingEnabledStates.isEmpty)
    }

    @Test func committedRequestCarriesPreviousValueAndTitle() async throws {
        let rowView = InspectorCommitRowSpy()
        var received: InspectorMutationRequest?
        let coordinator = InspectorPropertyCommitCoordinator(
            locale: Locale(identifier: "en_US_POSIX"),
            applyMutation: { request in
                received = request
                return true
            }
        )
        let previous = ViewScopeEditableProperty.number(key: "alpha", value: 1)

        await coordinator.commitNumber("0.5", property: previous, rowView: rowView, nodeID: "node-7", title: "Alpha")

        #expect(received?.nodeID == "node-7")
        #expect(received?.property == .number(key: "alpha", value: 0.5))
        #expect(received?.previousProperty == previous)
        #expect(received?.title == "Alpha")
    }
}

@MainActor
private final class InspectorCommitRowSpy: InspectorCommitCapable {
    private(set) var editingEnabledStates: [Bool] = []
    private(set) var resetDisplayedValueCallCount = 0

    func setEditingEnabled(_ enabled: Bool) {
        editingEnabledStates.append(enabled)
    }

    func resetDisplayedValue() {
        resetDisplayedValueCallCount += 1
    }
}
