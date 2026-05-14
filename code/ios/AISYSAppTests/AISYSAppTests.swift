import XCTest
@testable import AISYSApp

final class AISYSAppTests: XCTestCase {
    func testSaveWrongAnswerAddsItemToTop() {
        let store = ReviewStore()
        let originalCount = store.wrongAnswers.count

        store.saveWrongAnswer(
            note: WrongAnswerNote(
                title: "테스트 판례",
                confusionPoint: "구성요건 해석",
                memo: "최신 판례 문구 재확인"
            )
        )

        XCTAssertEqual(store.wrongAnswers.count, originalCount + 1)
        XCTAssertEqual(store.wrongAnswers.first?.title, "테스트 판례")
    }

    func testSaveWrongQuizRecordReturnsId() {
        let store = ReviewStore()
        let id = store.saveWrongQuizRecord(
            caseNumber: "2024도1",
            caseTitle: "테스트",
            question: "긴급체포 적법?",
            userAnswer: true,
            correctAnswer: false,
            explanation: "도주우려 부재",
            caseSummary: "요약",
            subject: "형소법"
        )
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(store.wrongQuizRecords.first?.id, id)
    }
}
