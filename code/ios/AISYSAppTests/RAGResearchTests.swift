import XCTest
@testable import AISYSApp

final class RAGResearchTests: XCTestCase {
    func testWithinDocumentRetrievalUsesOriginalSourceAndDoesNotApplyReferenceDiversityCap() throws {
        let source = document("source", text: String(repeating: "청색 표식 자료입니다. ", count: 100))
        let retriever = RAGRetriever(semanticScorer: { _, texts in texts.map { _ in 0.8 } })
        for mode in [RAGRetrievalMode.keyword, .semantic, .hybrid] {
            let result = try retriever.retrieveWithin(document: source, query: "청색", mode: mode)
            XCTAssertEqual(result.hits.count, 3)
            XCTAssertEqual(result.effectiveMode, mode)
            XCTAssertTrue(result.hits.allSatisfy { $0.chunk.documentID == source.id })
            if mode == .semantic { XCTAssertTrue(result.hits.allSatisfy { $0.keywordRank == nil }) }
        }
        XCTAssertThrowsError(try retriever.retrieveWithin(document: source, query: "", mode: .keyword))
        XCTAssertThrowsError(try retriever.retrieveWithin(document: source, query: "청색", mode: .currentOnly))
        XCTAssertThrowsError(try retriever.retrieveWithin(document: source, query: "청색", mode: .keyword, topK: 0))
    }

    func testUnicodeChunksAndExcerptsRetainExactOriginalRanges() throws {
        let text = String(repeating: "첫 문장 👨‍👩‍👧‍👦. 다음 문장 e\u{301} 한글입니다.\n", count: 30)
        let source = document("target", text: text)
        let chunks = try RAGChunker.chunks(for: source, size: 48, overlap: 12)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(chunks.first?.startUTF16, 0)
        XCTAssertEqual(chunks.last?.endUTF16, text.utf16.count)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: chunk.startUTF16, length: chunk.endUTF16 - chunk.startUTF16)), chunk.text)
            let excerpt = chunk.excerpt(limit: 13)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: excerpt.startUTF16, length: excerpt.endUTF16 - excerpt.startUTF16)), excerpt.text)
            if index > 0 {
                XCTAssertLessThan(chunk.startUTF16, chunks[index - 1].endUTF16)
                XCTAssertGreaterThan(chunk.startUTF16, chunks[index - 1].startUTF16)
            }
        }
        XCTAssertThrowsError(try RAGChunker.chunks(for: source, size: 32, overlap: 32))
        XCTAssertThrowsError(try RAGChunker.chunks(for: source, size: 10))
    }

    func testFullTextChangesBeyondLegacyPrefixInvalidateCorpus() throws {
        let first = document("target", text: String(repeating: "앞", count: 1600) + "변경 전")
        let second = document("target", text: String(repeating: "앞", count: 1600) + "변경 후")
        let item = try XCTUnwrap(first.extractedCase)
        let store = LocalCaseStore(seed: [])
        store.updateScanned(searchable: [item], display: [item], documents: [first])
        let revision = store.snapshot().revision
        store.updateScanned(searchable: [item], display: [item], documents: [second])
        XCTAssertGreaterThan(store.snapshot().revision, revision)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(store.snapshot().documents.first?.text, second.text)
    }

    func testExactCaseNumberRankingAndSelfExclusion() throws {
        let target = document("target", number: "2024도1", text: "현재 내용")
        let copy = document("copy", number: "2024 도 1", text: "자기 복제")
        let other = document("other", number: "2024도21", text: "참고 내용")
        let short = document("short", number: "2024도2", text: "무관한 내용")
        let duplicate = document("z-copy", number: "2024 도 21", text: "같은 사건 다른 저장")
        let result = try keywordRetriever.retrieve(query: "2024도21", target: target, documents: [target, copy, other, short, duplicate], mode: .keyword)
        XCTAssertEqual(result.hits.map(\.chunk.documentID), ["other"])
    }

    func testHybridFusesScoresAndReportsUnavailableEmbedding() throws {
        let target = document("target", text: "현재")
        let source = document("reference", text: "청색 표식")
        let hybrid = RAGRetriever(semanticScorer: { _, docs in docs.map { _ in 0.8 } })
        let result = try hybrid.retrieve(query: "무관한 질문", target: target, documents: [source], mode: .hybrid)
        XCTAssertEqual(result.effectiveMode, .hybrid)
        XCTAssertEqual(result.hits.first?.semanticRank, 1)
        let fallback = try keywordRetriever.retrieve(query: "청색", target: target, documents: [source], mode: .hybrid)
        XCTAssertEqual(fallback.effectiveMode, .keyword)
        XCTAssertFalse(fallback.warnings.isEmpty)
        let baseline = try hybrid.retrieve(query: "청색", target: target, documents: [source], mode: .currentOnly)
        XCTAssertTrue(baseline.hits.isEmpty)
        XCTAssertEqual(baseline.effectiveMode, .currentOnly)
        let broken = RAGRetriever(semanticScorer: { _, _ in [] })
        XCTAssertThrowsError(try broken.retrieve(query: "청색", target: target, documents: [source], mode: .hybrid))
    }

    func testRetrievalIsDeterministicAndLimitsRepeatedDocumentChunks() throws {
        let sources = ["b", "a"].map { document($0, text: String(repeating: "청색 표식 자료입니다. ", count: 100)) }
        let target = document("target", text: "현재")
        let a = try keywordRetriever.retrieve(query: "청색", target: target, documents: sources, mode: .keyword, topK: 10)
        let b = try keywordRetriever.retrieve(query: "청색", target: target, documents: sources.reversed(), mode: .keyword, topK: 10)
        XCTAssertEqual(a.hits.map(\.id), b.hits.map(\.id))
        XCTAssertEqual(a.hits.filter { $0.chunk.documentID == "a" }.count, 2)
    }

    func testSemanticOnlyUsesCosineWithoutLexicalOrExactCaseBonus() throws {
        let target = document("target", text: "현재")
        let exact = document("a", number: "2024도21", text: "청색")
        let semantic = document("b", number: "2024도22", text: "다른 표현")
        let retriever = RAGRetriever(semanticScorer: { _, _ in [0.4, 0.9] })
        let result = try retriever.retrieve(query: "청색 2024도21", target: target,
                                             documents: [target, semantic, exact], mode: .semantic)
        XCTAssertEqual(result.effectiveMode, .semantic)
        XCTAssertEqual(result.hits.map(\.chunk.documentID), ["b", "a"])
        XCTAssertEqual(result.hits.map(\.score), [0.9, 0.4])
        XCTAssertTrue(result.hits.allSatisfy { $0.keywordRank == nil })
        XCTAssertEqual(result.hits.map(\.semanticRank), [1, 2])
    }

    func testSemanticOnlyRejectsLowOrUnavailableScoresWithoutKeywordFallback() throws {
        let target = document("target", text: "현재")
        let source = document("source", text: "청색")
        let low = RAGRetriever(semanticScorer: { _, _ in [0.30] })
        let result = try low.retrieve(query: "청색", target: target, documents: [source], mode: .semantic)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.effectiveMode, .semantic)
        XCTAssertThrowsError(try keywordRetriever.retrieve(query: "청색", target: target,
                                                           documents: [source], mode: .semantic))
        let missing = RAGRetriever(provider: GGUFEmbeddingProvider(modelURL: nil))
        XCTAssertThrowsError(try missing.retrieve(query: "청색", target: target, documents: [source], mode: .semantic))
        let empty = try low.retrieve(query: "청색", target: target, documents: [], mode: .semantic)
        XCTAssertEqual(empty.effectiveMode, .semantic)
        XCTAssertTrue(empty.hits.isEmpty)
    }

    func testGroundingDistinguishesSyntaxUnknownCitationsNumbersAndQuotes() throws {
        let source = try evidence(document("source", text: "청색 표식은 7개다. 나무 보관함에 둔다."))
        let valid = try RAGGrounding.assess("[E0] 청색 표식은 7개다.", evidence: source)
        XCTAssertTrue(try XCTUnwrap(valid.first).passesBasicChecks)
        let invalid = try RAGGrounding.assess("[E0,E9] 청색 표식은 99개이며 “금속 보관함”이다.", evidence: source)
        XCTAssertEqual(invalid.first?.unknownCitationIDs, ["E9"])
        XCTAssertEqual(invalid.first?.unsupportedNumbers, ["99"])
        XCTAssertEqual(invalid.first?.quotedTextMatches, false)
        XCTAssertThrowsError(try RAGGrounding.assess("인용 없는 답", evidence: source))
        XCTAssertThrowsError(try RAGGrounding.assess("[E0] 청색 표식\n누락 문장", evidence: source))
        XCTAssertThrowsError(try RAGGrounding.assess("", evidence: source))
    }

    func testDatasetValidationRejectsDuplicateIDsAndTargetLeakage() throws {
        let source = document("source", text: "청색")
        let target = document("target", text: "청색")
        try dataset([source, target]).validate()
        XCTAssertThrowsError(try dataset([source, source, target]).validate())
        XCTAssertThrowsError(try dataset([source, target], relevant: ["target"]).validate())
        XCTAssertThrowsError(try dataset([source, target], relevant: ["missing"]).validate())
        XCTAssertThrowsError(try dataset([document("source", number: "2024도2", text: "원문"),
                                         document("target", number: "2024 도 2", text: "중복")]).validate())
        let bundled = try RAGEvaluationDataset.bundledSynthetic()
        XCTAssertEqual(bundled.kind, "synthetic")
        XCTAssertGreaterThanOrEqual(bundled.queries.count, 3)
    }

    func testRelevanceUsesDocumentDeduplicationAndExplicitEmptyGold() throws {
        let chunk = try XCTUnwrap(RAGChunker.chunks(for: document("source", text: "청색")).first)
        let hit = RAGHit(chunk: chunk, score: 1, keywordRank: 1, semanticRank: nil)
        let score = try RAGRelevanceMetrics.calculate(hits: [hit, hit], relevant: ["source"])
        XCTAssertEqual(score.precisionAtK, 1.0 / 3)
        XCTAssertEqual(score.recallAtK, 1)
        XCTAssertEqual(score.reciprocalRank, 1)
        XCTAssertEqual(score.evaluatedDocumentIDs, ["source"])
        let none = try RAGRelevanceMetrics.calculate(hits: [], relevant: [])
        XCTAssertNil(none.recallAtK)
        XCTAssertNil(none.reciprocalRank)
        XCTAssertEqual(none.noRelevantDocumentCorrect, true)
        XCTAssertThrowsError(try RAGRelevanceMetrics.calculate(hits: [], relevant: [], k: 0))
    }

    @MainActor
    func testResearchGenerationPassesExactBudgetedEvidenceWithoutLegacyPostprocessing() async throws {
        let engine = ResearchTestEngine()
        engine.limit = 450
        let llm = LLMService(primaryEngine: engine, caseStore: LocalCaseStore(seed: []))
        let service = RAGResearchService(llm: llm, retriever: keywordRetriever)
        let target = document("target", text: String(repeating: "청색 표식은 7개다. ", count: 40))
        let source = document("source", text: String(repeating: "청색 표식의 기록이다. ", count: 40))
        let run = try await service.run(target: target, question: "청색 표식", mode: .keyword, documents: [source])
        XCTAssertTrue(run.outputSuccess)
        XCTAssertEqual(run.generation?.output, engine.output)
        XCTAssertGreaterThan(engine.rejectedPrompts, 0)
        XCTAssertGreaterThanOrEqual(run.evidence.count, 2)
        let prompt = try XCTUnwrap(engine.prompts.last)
        for source in run.evidence {
            XCTAssertTrue(prompt.contains("[\(source.id)]"))
            XCTAssertTrue(prompt.contains(source.chunk.text))
            XCTAssertEqual(source.chunk.endUTF16 - source.chunk.startUTF16, source.chunk.text.utf16.count)
        }
        XCTAssertEqual(llm.state, .ready)
    }

    @MainActor
    func testBudgetFailureDoesNotBecomeModelSuccessOrExtractiveAnswer() async throws {
        let engine = ResearchTestEngine()
        engine.limit = 1
        let service = RAGResearchService(llm: LLMService(primaryEngine: engine), retriever: keywordRetriever)
        let run = try await service.run(target: document("target", text: "청색 표식"), question: "청색", mode: .currentOnly, documents: [])
        XCTAssertFalse(run.outputSuccess)
        XCTAssertNotNil(run.failureReason)
        XCTAssertNil(run.generation)
        XCTAssertTrue(engine.prompts.isEmpty)
    }

    @MainActor
    func testFailedAttemptsAreRecordedAndHumanReviewIsValidated() async throws {
        let engine = ResearchTestEngine()
        engine.failGeneration = true
        let llm = LLMService(primaryEngine: engine)
        let service = RAGResearchService(llm: llm, retriever: keywordRetriever)
        let target = document("target", text: "청색 표식은 7개다.")
        let failed = try await service.run(target: target, question: "청색", mode: .currentOnly, documents: [])
        XCTAssertFalse(failed.outputSuccess)
        XCTAssertEqual(failed.generation?.attempts, 2)
        XCTAssertNotNil(failed.generation?.failureReason)
        engine.failGeneration = false
        var good = try await service.run(target: target, question: "청색", mode: .currentOnly, documents: [])
        XCTAssertThrowsError(try good.review(reviewer: "", supportedClaims: 1))
        XCTAssertThrowsError(try good.review(reviewer: "reviewer", supportedClaims: 9))
        try good.review(reviewer: "reviewer", supportedClaims: 1)
        XCTAssertEqual(good.humanReview?.supportedClaims, 1)
    }

    @MainActor
    func testCancellationPropagatesWithoutRetryOrFallback() async throws {
        let engine = ResearchTestEngine()
        engine.delay = true
        let llm = LLMService(primaryEngine: engine)
        await llm.load()
        let started = expectation(description: "generation started")
        engine.onGenerate = { started.fulfill() }
        let service = RAGResearchService(llm: llm, retriever: keywordRetriever)
        let target = document("target", text: "청색")
        let operation = Task { try await service.run(target: target, question: "청색", mode: .currentOnly, documents: []) }
        await fulfillment(of: [started], timeout: 5)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("취소가 성공 결과로 반환됨")
        } catch is CancellationError {
            XCTAssertEqual(engine.prompts.count, 1)
            XCTAssertEqual(llm.state, .ready)
        }
    }

    @MainActor
    func testEvaluationExportsAllModesAndKeepsSimulatorPerformanceUnmeasured() async throws {
        let engine = ResearchTestEngine()
        let service = RAGResearchService(llm: LLMService(primaryEngine: engine), retriever: keywordRetriever)
        let report = try await RAGEvaluator.run(
            dataset: dataset([document("target", text: "청색"), document("source", text: "청색")]),
            service: service, progress: { _, _ in }
        )
        XCTAssertEqual(report.samples.count, 3)
        let hybrid = try XCTUnwrap(report.summaries.first { $0.mode == .hybrid })
        XCTAssertEqual(hybrid.effectiveModeMatchCount, 0)
        XCTAssertNil(hybrid.meanRecallAt3)
        XCTAssertNil(hybrid.humanGroundingRate)
        #if targetEnvironment(simulator)
        XCTAssertNil(hybrid.inferenceMedianMS)
        XCTAssertNil(hybrid.sampledPeakProcessMB)
        #endif
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertNotNil(json["summaries"])
        XCTAssertNotNil(json["samples"])
        XCTAssertNotNil(json["dataset"])
        let single = try await RAGEvaluator.run(
            dataset: report.dataset, modes: [.keyword], service: service, progress: { _, _ in }
        )
        XCTAssertEqual(single.samples.count, 1)
        do {
            _ = try await RAGEvaluator.run(dataset: report.dataset, modes: [], service: service, progress: { _, _ in })
            XCTFail("빈 평가 모드를 허용함")
        } catch RAGError.invalidInput {}
    }

    func testStoredDetailResolvesFullOriginalRatherThanExtractedFields() throws {
        let stored = document("saved", text: String(repeating: "원문 ", count: 800) + "끝")
        let item = try XCTUnwrap(stored.extractedCase)
        let resolved = RAGDocument.resolve(caseItem: item, rawText: "짧은 추출 필드", documents: [stored])
        XCTAssertEqual(resolved.text, stored.text)
        XCTAssertEqual(resolved.fingerprint, stored.fingerprint)
        let empty = try keywordRetriever.retrieve(query: "청색", target: stored, documents: [], mode: .hybrid)
        XCTAssertTrue(empty.hits.isEmpty)
        XCTAssertFalse(empty.warnings.isEmpty)
    }

    @MainActor
    func testSeparateGroundedOXDraftRequiresQuestionAnswerAndExplanation() async throws {
        let engine = ResearchTestEngine()
        engine.output = "[E0] 문항: 청색 표식은 7개다.\n[E0] 정답: O\n[E0] 해설: 청색 표식은 7개다."
        let service = RAGResearchService(llm: LLMService(primaryEngine: engine), retriever: keywordRetriever)
        let target = document("target", text: "청색 표식은 7개다.")
        let run = try await service.run(target: target, question: "청색", mode: .currentOnly, task: .oxDraft, documents: [])
        XCTAssertTrue(run.outputSuccess)
        XCTAssertEqual(run.quizDraft?.answer, true)
        XCTAssertTrue(engine.prompts.first?.contains("OX 1개") ?? false)
        engine.output = "[E0] 문항: 청색\n[E0] 정답: YES\n[E0] 해설: 표식"
        let malformed = try await service.run(target: target, question: "청색", mode: .currentOnly, task: .oxDraft, documents: [])
        XCTAssertFalse(malformed.outputSuccess)
        XCTAssertNil(malformed.quizDraft)
        XCTAssertNotNil(malformed.failureReason)
    }

    func testActualGGUFHybridRetrievalHasVerifiableModelIdentity() throws {
        let target = document("target", text: "현재 긴급체포 요건")
        let source = document("source", text: "긴급체포 요건과 도주 우려에 관한 판단")
        let result = try RAGRetriever().retrieve(query: "긴급체포 요건", target: target, documents: [source], mode: .hybrid)
        XCTAssertEqual(result.semanticScoredChunkCount, 1)
        XCTAssertEqual(result.effectiveMode, .hybrid)
        XCTAssertEqual(result.semanticModelIdentity["model"], "intfloat/multilingual-e5-base")
        XCTAssertEqual(result.semanticModelIdentity["dimensions"], "768")
        XCTAssertNotNil(result.semanticModelIdentity["sha256"])
        XCTAssertEqual(result.hits.first?.chunk.documentID, "source")
    }

    @MainActor
    func testRecoveryFailureIsVisibleAndNextRequestCanReload() async throws {
        let engine = ResearchTestEngine()
        engine.failGeneration = true
        engine.failRecoveryLoad = true
        let llm = LLMService(primaryEngine: engine)
        let service = RAGResearchService(llm: llm, retriever: keywordRetriever)
        let target = document("target", text: "청색 표식은 7개다.")
        let failed = try await service.run(target: target, question: "청색", mode: .currentOnly, documents: [])
        XCTAssertFalse(failed.outputSuccess)
        guard case .error = llm.state else { return XCTFail("복구 실패가 ready로 표시됨") }
        engine.failRecoveryLoad = false
        engine.failGeneration = false
        let recovered = try await service.run(target: target, question: "청색", mode: .currentOnly, documents: [])
        XCTAssertTrue(recovered.outputSuccess)
        XCTAssertEqual(llm.state, .ready)
    }

    private var keywordRetriever: RAGRetriever {
        RAGRetriever(semanticScorer: { _, docs in docs.map { _ in nil } })
    }

    private func document(_ id: String, number: String = "OCR-SYN", text: String) -> RAGDocument {
        RAGDocument(caseItem: APICase(id: id, caseNumber: number, caseName: id, courtName: "", subject: "",
                                    issueSummary: text, holdingSummary: nil, examPoints: nil, sourceUrl: nil), rawText: text)
    }

    private func evidence(_ source: RAGDocument) throws -> [RAGEvidence] {
        [RAGEvidence(id: "E0", chunk: try XCTUnwrap(RAGChunker.chunks(for: source).first))]
    }

    private func dataset(_ documents: [RAGDocument], relevant: [String] = ["source"]) -> RAGEvaluationDataset {
        RAGEvaluationDataset(schemaVersion: 1, id: "unit", kind: "synthetic", provenance: "unit test",
                             annotator: "test", documents: documents,
                             queries: [RAGEvaluationQuery(id: "q", targetDocumentID: "target", question: "청색", relevantDocumentIDs: relevant)])
    }
}

private final class ResearchTestEngine: LocalLLMEngine {
    let name = "fake-not-GGUF"
    var output = "[E0] 청색 표식은 7개다."
    var prompts: [String] = []
    var limit: Int?
    var rejectedPrompts = 0
    var failGeneration = false
    var delay = false
    var onGenerate: (() -> Void)?
    var failRecoveryLoad = false
    private var loadCount = 0
    func loadModel() async throws {
        loadCount += 1
        if failRecoveryLoad && loadCount > 1 { throw RAGError.unavailable("테스트 모델 복구 실패") }
    }
    func resetModel() async {}
    func validatePrompt(_ prompt: String, maxTokens: Int) throws {
        if let limit, prompt.count > limit {
            rejectedPrompts += 1
            throw LocalLLMEngineError.promptTooLong(actual: prompt.count, limit: limit)
        }
    }
    func generate(prompt: String, maxTokens: Int) async throws -> String {
        prompts.append(prompt)
        onGenerate?()
        if delay { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if failGeneration { throw RAGError.unavailable("테스트 생성 실패") }
        return output
    }
}
