import XCTest
@testable import FinApp

@MainActor
final class TriageStateTests: XCTestCase {
    func testActionGateRejectsASecondActionUntilFinished() {
        var gate = TriageActionGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.finish()
        XCTAssertTrue(gate.begin())
    }

    func testUndoInvalidatesPendingFlingCompletion() {
        var sequence = TriageFlingSequence()
        let captured = sequence.generation  // fling animation starts
        sequence.invalidate()               // user taps Undo mid-animation

        XCTAssertFalse(sequence.isCurrent(captured),
                       "A fling completion captured before an undo must not advance")
    }

    func testFlingCompletionAdvancesWhenNoUndoIntervened() {
        let sequence = TriageFlingSequence()
        XCTAssertTrue(sequence.isCurrent(sequence.generation))
    }

    func testCancelledUndoExpiryDoesNotClearCurrentUndo() async {
        let token = UUID()
        var current: UUID? = token
        let task = Task {
            await TriageUndoExpiry.wait(
                token: token,
                duration: .seconds(30),
                currentToken: { current },
                clear: { current = nil }
            )
        }

        task.cancel()
        await task.value

        XCTAssertEqual(current, token)
    }

    func testOlderUndoExpiryCannotClearANewerUndo() async {
        let old = UUID()
        let current = UUID()
        var stored: UUID? = current

        await TriageUndoExpiry.wait(
            token: old,
            duration: .zero,
            currentToken: { stored },
            clear: { stored = nil }
        )

        XCTAssertEqual(stored, current)
    }
}
