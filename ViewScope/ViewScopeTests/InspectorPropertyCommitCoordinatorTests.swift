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
            applyMutation: { _, property in
                receivedMutation = property
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
            applyMutation: { _, property in
                receivedMutation = property
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
            applyMutation: { _, _ in false }
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
