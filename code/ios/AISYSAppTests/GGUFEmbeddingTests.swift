import XCTest
@testable import AISYSApp

final class GGUFEmbeddingTests: XCTestCase {
    func testRealKoreanEmbeddingsRankParaphraseAboveUnrelatedTextAndReuseExactVectors() throws {
        let provider = GGUFEmbeddingProvider(modelURL: try modelURL())
        let query = "경찰이 영장 없이 사람을 체포할 수 있는 요건"
        let texts = [
            "긴급체포는 피의자를 영장 없이 체포하는 절차이며 긴급성과 도주 우려를 검토한다.",
            "오늘의 점심 메뉴는 딸기 케이크와 바닐라 아이스크림이다."
        ]
        let first = try provider.scores(query: query, documents: texts)
        let relevant = try XCTUnwrap(first.scores[0])
        let unrelated = try XCTUnwrap(first.scores[1])
        XCTAssertTrue(relevant.isFinite && unrelated.isFinite)
        XCTAssertGreaterThan(relevant, unrelated)
        XCTAssertLessThanOrEqual(abs(relevant), 1.00001)
        XCTAssertEqual(first.identity["warmBeforeSearch"], "false")
        XCTAssertEqual(first.identity["vectorCacheMisses"], "3")
        XCTAssertEqual(first.identity["queryPrefix"], "query: ")
        XCTAssertEqual(first.identity["documentPrefix"], "passage: ")
        XCTAssertEqual(first.identity["tokenizer"], "t5")
        let repeated = try provider.scores(query: query, documents: texts)
        XCTAssertEqual(repeated.scores, first.scores)
        XCTAssertEqual(repeated.identity["vectorCacheHits"], "3")
        XCTAssertEqual(repeated.identity["vectorCacheMisses"], "0")
        let changed = try provider.scores(query: query, documents: [texts[0] + " 변경", texts[1]])
        XCTAssertEqual(changed.identity["vectorCacheMisses"], "1")
    }

    func testOversizedEmbeddingDoesNotSilentlyTruncateSource() throws {
        let provider = GGUFEmbeddingProvider(modelURL: try modelURL())
        let result = try provider.scores(query: "체포", documents: [String(repeating: "긴급체포 요건과 도주 우려 ", count: 1000)])
        XCTAssertNil(result.scores[0])
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testCorruptEmbeddingIsRejectedBeforeNativeModelLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        try Data("invalid model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = GGUFEmbeddingProvider(modelURL: url)
        XCTAssertThrowsError(try provider.scores(query: "체포", documents: ["체포 요건"])) {
            XCTAssertTrue($0.localizedDescription.contains("SHA-256"))
        }
    }

    func testEmbeddingWeightsCannotBeSelectedAsGenerativeModel() {
        XCTAssertFalse(LocalLLMModelLocator.isGenerationModelFileName(GGUFEmbeddingProvider.fileName))
        XCTAssertFalse(LocalLLMModelLocator.isGenerationModelFileName(GGUFEmbeddingProvider.fileName.uppercased()))
        XCTAssertFalse(LocalLLMModelLocator.isGenerationModelFileName("multilingual-e5-small-Q8_0.gguf"))
        XCTAssertTrue(LocalLLMModelLocator.isGenerationModelFileName("Llama-3.2-1B-Instruct-Q4_K_M.gguf"))
        XCTAssertFalse(LocalLLMModelLocator.isGenerationModelFileName("model.json"))
    }

    func testMissingEmbeddingIsVisibleAsEffectiveKeywordMode() throws {
        let provider = GGUFEmbeddingProvider(modelURL: nil)
        let make: (String) -> RAGDocument = { id in
            RAGDocument(caseItem: APICase(id: id, caseNumber: id, caseName: id, courtName: "", subject: "",
                                        issueSummary: "긴급체포 요건", holdingSummary: nil, examPoints: nil, sourceUrl: nil))
        }
        let result = try RAGRetriever(provider: provider).retrieve(
            query: "긴급체포", target: make("current"), documents: [make("reference")], mode: .hybrid
        )
        XCTAssertEqual(result.effectiveMode, .keyword)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(result.semanticModelIdentity["status"], "unavailable")
    }

    @MainActor
    func testRealGGUFAndEmbeddingProduceCitedResearchOutput() async throws {
        let make: (String, String) -> RAGDocument = { id, text in
            RAGDocument(caseItem: APICase(id: id, caseNumber: id, caseName: "가상 표식 규칙", courtName: "", subject: "",
                                        issueSummary: text, holdingSummary: nil, examPoints: nil, sourceUrl: nil))
        }
        let target = make("SYN-CURRENT", "현재 문서: 청색 표식을 확인한다.")
        let reference = make("SYN-REFERENCE", "참고 문서: 청색 표식이 있으면 기록한다.")
        let llm = LLMService(primaryEngine: LlamaCppEngine(), caseStore: LocalCaseStore(seed: []))
        let service = RAGResearchService(llm: llm)
        let run = try await service.run(target: target, question: "청색 표식을 한 문장으로 설명.", mode: .hybrid, documents: [reference])
        XCTAssertEqual(run.search.effectiveMode, .hybrid)
        XCTAssertFalse(llm.isUsingFallbackEngine)
        XCTAssertNotNil(run.generation)
        XCTAssertNil(run.generation?.failureReason)
        XCTAssertTrue(run.outputSuccess, "실제 생성 결과: \(run.generation?.output ?? "없음"); 오류: \(run.failureReason ?? "없음")")
        XCTAssertGreaterThanOrEqual(run.evidence.count, 2)
    }

    private func modelURL() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: GGUFEmbeddingProvider.fileName, withExtension: nil),
                      "Run scripts/fetch_rag_embedding.sh and xcodegen generate before testing.")
    }
}
