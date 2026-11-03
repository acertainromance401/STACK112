import XCTest
import SwiftData
import SwiftUI
import UIKit
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

    func testCorpusRevisionChangesForAddsEditsAndDeletesOnly() {
        let store = LocalCaseStore(seed: [])
        let original = makeCase(id: "saved", number: "2024도2")
        XCTAssertEqual(store.snapshot().revision, 0)
        store.updateScanned([original])
        XCTAssertEqual(store.snapshot().revision, 1)
        store.updateScanned([original])
        XCTAssertEqual(store.snapshot().revision, 1)
        let edited = makeCase(id: "saved", number: "2024도2", holding: "긴급체포가 위법하다.")
        store.updateScanned([edited])
        XCTAssertEqual(store.snapshot().revision, 2)
        XCTAssertEqual(store.snapshot().display, [edited])
        store.updateScanned([])
        XCTAssertEqual(store.snapshot().revision, 3)
        XCTAssertTrue(store.snapshot().searchable.isEmpty)
    }

    func testOCRCaseRetrievesWithoutBeingRegistered() async throws {
        let reference = makeCase(id: "saved", number: "2024도2")
        let network = NetworkService(store: LocalCaseStore(seed: [reference]))
        let result = try await network.listSimilarCases(caseItem: makeCase())
        XCTAssertEqual(result.map(\.id), ["saved"])
    }

    func testRetrievalExcludesSelfDuplicatesAndUnrelatedCases() {
        let target = makeCase(id: "current", number: "2024도1")
        let pool = [
            target,
            makeCase(id: "self-copy", number: "2024 도 1"),
            makeCase(id: "b", number: "2024도2"),
            makeCase(id: "a", number: "2024도2"),
            makeCase(id: "fraud", number: "2024도3", name: "사기 사건", issue: "기망행위 판단", holding: "사기죄가 성립한다.", exam: "사기"),
        ]
        let result = LocalCaseSearchEngine.similar(to: target, in: pool)
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testEmptyCaseDoesNotRetrieveArbitraryEvidence() {
        let empty = makeCase(name: "", issue: nil, holding: nil, exam: nil)
        XCTAssertTrue(LocalCaseSearchEngine.similar(to: empty, in: [makeCase(id: "other")]).isEmpty)
    }

    func testRankingIsDeterministic() {
        let a = makeCase(id: "a", number: "2024도2")
        let b = makeCase(id: "b", number: "2024도3")
        XCTAssertEqual(LocalCaseSearchEngine.similar(to: makeCase(), in: [b, a]).map(\.id), ["a", "b"])
        XCTAssertEqual(LocalCaseSearchEngine.similar(to: makeCase(), in: [a, b]).map(\.id), ["a", "b"])
    }

    @MainActor
    func testScannedCaseEditsRefreshSearchButDoNotExposeOCRRawText() async throws {
        let container = try ModelContainer(for: ScannedCase.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let scanned = ScannedCase(
            id: "saved", ocrRawText: "비공개검색어 긴급체포",
            keywords: ["긴급체포"], keySentences: "체포 요건",
            caseNumber: "2024도2", caseName: "저장 판례", rulingPoint: "위법하다."
        )
        context.insert(scanned)
        try context.save()
        let store = LocalCaseStore(seed: [])
        var records = try context.fetch(FetchDescriptor<ScannedCase>())
        store.updateScanned(searchable: records.map { $0.toSearchableAPICase() }, display: records.map { $0.toAPICase() })
        let oldSnapshot = store.snapshot()
        let network = NetworkService(store: store)
        let hits = try await network.searchCases(query: "비공개검색어")
        XCTAssertEqual(hits.count, 1)
        XCTAssertFalse(hits[0].issueSummary?.contains("비공개검색어") ?? true)
        let similar = try await network.listSimilarCases(caseItem: makeCase())
        XCTAssertFalse(similar[0].issueSummary?.contains("비공개검색어") ?? true)

        scanned.rulingPoint = "적법하다."
        try context.save()
        records = try context.fetch(FetchDescriptor<ScannedCase>())
        store.updateScanned(searchable: records.map { $0.toSearchableAPICase() }, display: records.map { $0.toAPICase() })
        XCTAssertGreaterThan(store.snapshot().revision, oldSnapshot.revision)
        XCTAssertEqual(store.snapshot().display.first?.holdingSummary, "적법하다.")
        XCTAssertEqual(oldSnapshot.display.first?.holdingSummary, "위법하다.")
        context.delete(scanned)
        try context.save()
        records = try context.fetch(FetchDescriptor<ScannedCase>())
        store.updateScanned(searchable: records.map { $0.toSearchableAPICase() }, display: records.map { $0.toAPICase() })
        XCTAssertTrue(store.snapshot().display.isEmpty)
    }

    @MainActor
    func testRootSynchronizesInitialDataSameCountEditsAndDeletion() async throws {
        let container = try ModelContainer(for: ScannedCase.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scanned = ScannedCase(
            ocrRawText: String(repeating: "첫부분", count: 600) + "끝부분 초기값",
            keywords: ["긴급체포"], keySentences: "체포 요건",
            caseNumber: "2024도2", caseName: "저장 판례", rulingPoint: "위법하다."
        )
        container.mainContext.insert(scanned)
        try container.mainContext.save()
        let store = LocalCaseStore(seed: [])
        let root = RootTabView(caseStore: store)
            .environmentObject(AppRuntimeState())
            .environmentObject(ReviewStore())
            .modelContainer(container)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            store.snapshot().display.first?.holdingSummary == "위법하다."
        }, object: nil)
        await fulfillment(of: [initial], timeout: 5)
        let revision = store.snapshot().revision
        scanned.rulingPoint = "적법하다."
        try container.mainContext.save()
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            store.snapshot().revision > revision && store.snapshot().display.first?.holdingSummary == "적법하다."
        }, object: nil)
        await fulfillment(of: [edited], timeout: 5)
        let fullTextRevision = store.snapshot().revision
        let fullText = String(repeating: "첫부분", count: 600) + "끝부분 수정 감지"
        scanned.ocrRawText = fullText
        try container.mainContext.save()
        let fullTextEdited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            store.snapshot().revision > fullTextRevision && store.snapshot().documents.first?.text == fullText
        }, object: nil)
        await fulfillment(of: [fullTextEdited], timeout: 5)
        container.mainContext.delete(scanned)
        try container.mainContext.save()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            store.snapshot().display.isEmpty
        }, object: nil)
        await fulfillment(of: [deleted], timeout: 5)
    }

    @MainActor
    func testSummaryDeliversCurrentCaseEvidenceAndOutputFormatToEngine() async throws {
        let engine = RecordingLLMEngine()
        engine.promptLimit = 560
        let longIssue = String(repeating: "긴급체포 요건과 영장주의 판단. ", count: 40)
        let store = LocalCaseStore(seed: [makeCase(id: "saved", number: "2024도2", issue: longIssue, holding: "위법하다." + longIssue)])
        let service = LLMService(primaryEngine: engine, caseStore: store)
        await service.load()
        let summary = try await service.summarize(caseItem: makeCase(issue: longIssue, holding: "적법하다." + longIssue))
        XCTAssertNotNil(summary)
        let prompt = try XCTUnwrap(engine.prompts.last)
        XCTAssertLessThanOrEqual(prompt.count, 560)
        XCTAssertTrue(prompt.contains("[현재 판례]"))
        XCTAssertTrue(prompt.contains("OCR-NEW"))
        XCTAssertTrue(prompt.contains("적법하다."))
        XCTAssertTrue(prompt.contains("[참고 판례]"))
        XCTAssertTrue(prompt.contains("[R1] 2024도2"))
        XCTAssertTrue(prompt.contains("위법하다."))
        XCTAssertTrue(prompt.contains("포인트:"))
        XCTAssertTrue(prompt.contains("<|start_header_id|>assistant<|end_header_id|>"))
        XCTAssertFalse(prompt.contains("[예시"))
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertGreaterThan(engine.rejectedPrompts, 0)
    }

    @MainActor
    func testSummaryCacheUsesFullCaseContents() async throws {
        let engine = RecordingLLMEngine()
        let service = LLMService(primaryEngine: engine, caseStore: LocalCaseStore(seed: []))
        await service.load()
        _ = try await service.summarize(caseItem: makeCase())
        _ = try await service.summarize(caseItem: makeCase())
        XCTAssertEqual(engine.prompts.count, 1)
        _ = try await service.summarize(caseItem: makeCase(holding: "긴급체포가 위법하다."))
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertTrue(engine.prompts[1].contains("긴급체포가 위법하다."))
    }

    @MainActor
    func testCorpusChangesInvalidateSummaryAndEmptyEvidenceCaches() async throws {
        let engine = RecordingLLMEngine()
        let store = LocalCaseStore(seed: [])
        let service = LLMService(primaryEngine: engine, caseStore: store)
        await service.load()
        _ = try await service.summarize(caseItem: makeCase())
        XCTAssertFalse(engine.prompts[0].contains("[참고 판례]"))
        store.updateScanned([makeCase(id: "saved", number: "2024도2", holding: "위법하다.")])
        _ = try await service.summarize(caseItem: makeCase())
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertTrue(engine.prompts[1].contains("[R1] 2024도2"))
        store.updateScanned([makeCase(id: "saved", number: "2024도2", holding: "증거능력이 없다.")])
        _ = try await service.summarize(caseItem: makeCase())
        XCTAssertEqual(engine.prompts.count, 3)
        XCTAssertTrue(engine.prompts[2].contains("증거능력이 없다."))
        store.updateScanned([])
        _ = try await service.summarize(caseItem: makeCase())
        XCTAssertEqual(engine.prompts.count, 4)
        XCTAssertFalse(engine.prompts[3].contains("[참고 판례]"))
        await service.load()
        _ = try await service.summarize(caseItem: makeCase())
        XCTAssertEqual(engine.prompts.count, 5)
    }

    @MainActor
    func testOversizedSummaryIsReportedInsteadOfDroppingEvidence() async throws {
        let engine = RecordingLLMEngine()
        engine.promptLimit = 20
        let service = LLMService(primaryEngine: engine, caseStore: LocalCaseStore(seed: [makeCase(id: "saved", number: "2024도2")]))
        await service.load()
        let summary = try await service.summarize(caseItem: makeCase())
        XCTAssertNotNil(summary)
        XCTAssertTrue(engine.prompts.isEmpty)
        XCTAssertTrue(service.lastLoadMessage?.contains("입력 예산") ?? false)
        XCTAssertEqual(service.state, .ready)
    }

    func testRuleBasedSummaryDoesNotUseReferenceRuling() async throws {
        let prompt = LLMPromptTemplate.summarize(
            caseNumber: "OCR-NEW", caseName: "현재체포", issue: "긴급체포 요건",
            holding: "적법하다.", examPoints: "긴급체포",
            ragEvidence: "[R1] 2024도2\n쟁점: 긴급체포\n판결: 위법하다."
        )
        let output = try await RuleBasedLocalEngine().generate(prompt: prompt, maxTokens: 160)
        let summary = try XCTUnwrap(LLMSummary(rawOutput: output))
        XCTAssertEqual(summary.rulingPoint, "적법하다.")
        XCTAssertFalse(output.contains("위법하다."))
    }

    @MainActor
    func testRealTokenizerPreservesEvidenceAndRepeatedInferenceWorks() async throws {
        guard let modelURL = LocalLLMModelLocator.resolveModel(ignoreDocuments: true).selectedURL else {
            throw XCTSkip("번들 GGUF가 없어 실제 tokenizer/추론 검증을 생략합니다.")
        }
        let llama = LlamaCppEngine(modelURL: modelURL)
        try await llama.loadModel()
        let engine = RecordingLLMEngine()
        engine.validator = { prompt, maxTokens in try llama.validatePrompt(prompt, maxTokens: maxTokens) }
        let store = LocalCaseStore(seed: [makeCase(id: "saved", number: "2024도2", holding: "위법하다.")])
        let service = LLMService(primaryEngine: engine, caseStore: store)
        await service.load()
        let longIssue = String(repeating: "긴급체포 요건과 영장주의 판단. ", count: 40)
        _ = try await service.summarize(caseItem: makeCase(issue: longIssue, holding: "적법하다."))
        let prompt = try XCTUnwrap(engine.prompts.last)
        XCTAssertTrue(prompt.contains("OCR-NEW"))
        XCTAssertTrue(prompt.contains("[R1] 2024도2"))
        XCTAssertTrue(prompt.contains("위법하다."))
        XCTAssertTrue(prompt.contains("포인트:"))
        try llama.validatePrompt(prompt, maxTokens: 220)
        do {
            try llama.validatePrompt(String(repeating: prompt, count: 20), maxTokens: 220)
            XCTFail("예산 초과 입력은 거부해야 합니다.")
        } catch LocalLLMEngineError.promptTooLong(let actual, let limit) {
            XCTAssertGreaterThan(actual, limit)
            XCTAssertLessThanOrEqual(limit, 512)
        }
        let first = try await llama.generate(prompt: prompt, maxTokens: 8)
        let second = try await llama.generate(prompt: prompt, maxTokens: 8)
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        await llama.resetModel()
    }

    private func makeCase(
        id: String = "current", number: String = "OCR-NEW", name: String = "현재체포",
        issue: String? = "긴급체포 요건", holding: String? = "긴급체포가 적법하다.", exam: String? = "긴급체포"
    ) -> APICase {
        APICase(
            id: id, caseNumber: number, caseName: name, courtName: "대법원", subject: "형사소송법",
            issueSummary: issue, holdingSummary: holding, examPoints: exam, sourceUrl: nil
        )
    }
}

private final class RecordingLLMEngine: LocalLLMEngine {
    let name = "recording-test-engine"
    var prompts: [String] = []
    var promptLimit: Int?
    var rejectedPrompts = 0
    var validator: ((String, Int) throws -> Void)?

    func loadModel() async throws {}
    func resetModel() async {}

    func validatePrompt(_ prompt: String, maxTokens: Int) throws {
        try validator?(prompt, maxTokens)
        if let promptLimit, prompt.count > promptLimit {
            rejectedPrompts += 1
            throw LocalLLMEngineError.promptTooLong(actual: prompt.count, limit: promptLimit)
        }
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        try validatePrompt(prompt, maxTokens: maxTokens)
        prompts.append(prompt)
        return """
        한줄요약: 긴급체포 요건 판단 사례
        핵심쟁점: 긴급체포 요건 충족 여부
        결론: 긴급체포가 적법하다.
        포인트: 긴급체포, 영장주의
        """
    }
}
