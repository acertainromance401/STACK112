import XCTest
@testable import AISYSApp

final class LongSummaryEvaluationTests: XCTestCase {
    @MainActor
    func testRealLongJudgmentSummaryComparison() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "family_law_retrieval_v1", withExtension: "json"))
        let dataset = try JSONDecoder().decode(RAGEvaluationDataset.self, from: Data(contentsOf: url))
        try dataset.validate()
        let embeddingURL = try XCTUnwrap(Bundle.main.url(forResource: GGUFEmbeddingProvider.fileName, withExtension: nil))
        let engine = LlamaCppEngine()
        let store = LocalCaseStore(seed: [])
        let llm = LLMService(primaryEngine: engine, caseStore: store)
        let loadStart = ProcessInfo.processInfo.systemUptime
        await llm.load()
        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        XCTAssertFalse(llm.isUsingFallbackEngine)
        guard !llm.isUsingFallbackEngine else { throw RAGError.unavailable("실제 Llama 엔진이 필요합니다.") }
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("long-summary-evaluation-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let modes = ["fields", "keyword", "semantic", "hybrid"]
        let queries = ["핵심 쟁점 판시사항", "판단 이유 법리 원칙 예외", "주문 결론 파기 환송 기각"]
        var samples: [LongSummarySample] = []
        for (index, document) in dataset.documents.enumerated() {
            let parsed = JudgmentParser.parse(document.text)
            XCTAssertFalse(parsed.issues.isEmpty)
            XCTAssertFalse(parsed.holdings.isEmpty)
            for offset in modes.indices {
                let mode = modes[(index + offset) % modes.count]
                let start = ProcessInfo.processInfo.systemUptime
                var searches: [RAGSearchResult] = []
                var fields = [parsed.issues.joined(separator: "\n"),
                              parsed.holdings.map(\.text).joined(separator: "\n"), parsed.statutesRaw ?? ""]
                if mode != "fields" {
                    let retrievalMode = try XCTUnwrap(RAGRetrievalMode(rawValue: mode))
                    let provider = GGUFEmbeddingProvider(modelURL: embeddingURL)
                    let retriever = RAGRetriever(provider: provider)
                    fields = try queries.map { query in
                        let search = try retriever.retrieveWithin(document: document, query: query, mode: retrievalMode)
                        XCTAssertEqual(search.effectiveMode, retrievalMode)
                        if retrievalMode != .keyword {
                            XCTAssertEqual(search.semanticScoredChunkCount, search.chunkCount)
                        }
                        searches.append(search)
                        return try XCTUnwrap(search.hits.first, "요약 근거를 찾지 못했습니다: \(query)").chunk.text
                    }
                }
                let input = APICase(id: document.id, caseNumber: document.caseNumber, caseName: document.title,
                                    courtName: "대법원", subject: document.subject,
                                    issueSummary: fields[0], holdingSummary: fields[1], examPoints: fields[2],
                                    sourceUrl: document.sourceURL)
                let prompt = try llm.prepareSummaryPrompt(caseItem: input, references: [])
                let wrapped = llm.wrapForLlama3Instruct(userPrompt: prompt, purpose: "summarize")
                let selectionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let generationStart = ProcessInfo.processInfo.systemUptime
                let tokenCap = ProcessInfo.processInfo.physicalMemory / 1_073_741_824 <= 6 ? 160 : 220
                var output = ""
                var failure: String?
                do {
                    output = try await engine.generate(prompt: wrapped, maxTokens: tokenCap)
                } catch {
                    failure = error.localizedDescription
                    XCTFail("실제 요약 생성 실패: \(failure ?? "")")
                }
                let generationMS = (ProcessInfo.processInfo.systemUptime - generationStart) * 1000
                let sample = LongSummarySample(
                    documentID: document.id, mode: mode, sourceSHA256: document.fingerprint,
                    input: input, searches: searches, prompt: prompt, wrappedPrompt: wrapped,
                    rawOutput: output, formatParsed: LLMSummary(rawOutput: output) != nil,
                    failureReason: failure, selectionMS: selectionMS, generationMS: generationMS,
                    totalMS: (ProcessInfo.processInfo.systemUptime - start) * 1000
                )
                try encoder.encode(sample).write(to: directory.appendingPathComponent("\(document.id)-\(mode).json"), options: .atomic)
                samples.append(sample)
                print("LONG_SUMMARY_SAMPLE document=\(document.id) mode=\(mode) selectionMS=\(selectionMS) generationMS=\(generationMS)")
                print("LONG_SUMMARY_OUTPUT \(output)")
            }
        }
        let fingerprint = try await RAGResearchService(store: store, llm: llm).modelFingerprint()
        let report = LongSummaryReport(
            schemaVersion: 1, dataset: dataset, modelSHA256: fingerprint, generationModelLoadMS: loadMS,
            configuration: [
                "environment": "simulator_not_device_evidence",
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "scope": "raw Llama summary; no UI postprocessing, normalization, rule-based fallback, OCR or expert review",
                "baseline": "production summary template/budget with JudgmentParser issue/holding/statute fields; external references disabled",
                "selectors": "same document only; one top chunk for each of three generic facets; no case-specific gold provided",
                "facetQueries": queries.joined(separator: " | "),
                "budget": "unchanged production field limits [96,64,48,32,16,8], template and chat wrapper; maxTokens 160/220 by host memory",
                "runtime": "unchanged LlamaCppEngine context/output caps/sampling; model loaded once before timed cells",
                "embedding": "fresh provider per semantic/hybrid cell; passage cache reused across its 3 facets; cold selection costs included",
                "order": "document order; four-mode order rotated by document index; one sample per cell",
                "review": "provisional source-bounded AI review; not independent legal expert accuracy"
            ], samples: samples
        )
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        XCTAssertEqual(samples.count, 12)
        XCTAssertTrue(samples.allSatisfy { $0.failureReason == nil && !$0.rawOutput.isEmpty })
        XCTAssertNotNil(fingerprint)
        print("LONG_SUMMARY_FINISHED \(directory.path)")
    }
}

private struct LongSummarySample: Encodable {
    let documentID: String
    let mode: String
    let sourceSHA256: String
    let input: APICase
    let searches: [RAGSearchResult]
    let prompt: String
    let wrappedPrompt: String
    let rawOutput: String
    let formatParsed: Bool
    let failureReason: String?
    let selectionMS: Double
    let generationMS: Double
    let totalMS: Double
}

private struct LongSummaryReport: Encodable {
    let schemaVersion: Int
    let dataset: RAGEvaluationDataset
    let modelSHA256: String?
    let generationModelLoadMS: Double
    let configuration: [String: String]
    let samples: [LongSummarySample]
}
