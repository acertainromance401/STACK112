import XCTest
@testable import AISYSApp

final class LegalCasePilotTests: XCTestCase {
    @MainActor
    func testRealThreeJudgmentRetrievalAndGenerationPilot() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "family_law_retrieval_v1", withExtension: "json"))
        let dataset = try JSONDecoder().decode(RAGEvaluationDataset.self, from: Data(contentsOf: url))
        try dataset.validate()
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: GGUFEmbeddingProvider.fileName, withExtension: nil))
        let provider = GGUFEmbeddingProvider(modelURL: modelURL)
        let store = LocalCaseStore(seed: [])
        let llm = LLMService(primaryEngine: LlamaCppEngine(), caseStore: store)
        let service = RAGResearchService(store: store, llm: llm, retriever: RAGRetriever(provider: provider))
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("legal-case-pilot-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var samples: [RAGEvaluationSample] = []
        for query in dataset.queries {
            let target = try XCTUnwrap(dataset.documents.first { $0.id == query.targetDocumentID })
            for mode in RAGRetrievalMode.baselineModes {
                let run = try await service.run(target: target, question: query.question, mode: mode, documents: dataset.documents)
                samples.append(RAGEvaluationSample(
                    queryID: query.id, repetition: 1,
                    relevance: try .calculate(hits: run.search.hits, relevant: query.relevantDocumentIDs), run: run
                ))
                let checkpoint = directory.appendingPathComponent("\(query.id)-\(mode.rawValue).json")
                try encoder.encode(RAGRunExport(run: run)).write(to: checkpoint, options: .atomic)
                print("LEGAL_PILOT_SAMPLE query=\(query.id) mode=\(mode.rawValue) success=\(run.outputSuccess) file=\(checkpoint.path)")
                print("LEGAL_PILOT_OUTPUT \(run.generation?.output ?? "<no generation>")")
            }
        }
        let report = RAGEvaluationReport(
            schemaVersion: 1, dataset: dataset, modelSHA256: try await service.modelFingerprint(),
            configuration: [
                "experiment": "three real judgments, three queries, three retrieval modes, one sample per cell",
                "purpose": "frozen-baseline functional/output-quality pilot; not physical-device performance",
                "generation": "unchanged production settings; temperature=0.4,topK=40,topP=0.9,repeatPenalty=1.1,LLAMA_DEFAULT_SEED",
                "retrieval": "320-character chunks,64 overlap,3 hits,2 chunks/document,RRF=60,cosine>0.30",
                "evidence": "unchanged E0 plus up to two retrieved chunks; production prompt budgeting",
                "order": "query order, then currentOnly/keyword/hybrid; no repeats or randomization",
                "review": "provisional source-bounded AI review; no independent legal expert labels"
            ], samples: samples
        )
        try report.encoded().write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        var diagnostic: [CosineObservation] = []
        for query in dataset.queries {
            let target = try XCTUnwrap(dataset.documents.first { $0.id == query.targetDocumentID })
            let chunks = try dataset.documents.filter { $0.id != target.id }.sorted { $0.id < $1.id }
                .flatMap { try RAGChunker.chunks(for: $0) }
            let scores = try provider.scores(query: query.question + " " + target.title, documents: chunks.map(\.text))
            for (chunk, score) in zip(chunks, scores.scores) {
                diagnostic.append(CosineObservation(queryID: query.id, chunk: chunk, cosine: score))
            }
        }
        try encoder.encode(diagnostic).write(to: directory.appendingPathComponent("cosines.json"), options: .atomic)
        XCTAssertEqual(samples.count, 9)
        XCTAssertFalse(llm.isUsingFallbackEngine)
        XCTAssertNotNil(report.modelSHA256)
        XCTAssertEqual(llm.selectedModelPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                       "Llama-3.2-1B-Instruct-Q4_K_M.gguf")
        print("LEGAL_PILOT_FINISHED \(directory.path)")
    }

    func testRetrievalOnlyKeywordSemanticHybridAblation() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "family_law_retrieval_v1", withExtension: "json"))
        let dataset = try JSONDecoder().decode(RAGEvaluationDataset.self, from: Data(contentsOf: url))
        try dataset.validate()
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: GGUFEmbeddingProvider.fileName, withExtension: nil))
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("retrieval-ablation-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let modes: [RAGRetrievalMode] = [.keyword, .semantic, .hybrid]
        var samples: [RetrievalAblationSample] = []
        for (index, query) in dataset.queries.enumerated() {
            let target = try XCTUnwrap(dataset.documents.first { $0.id == query.targetDocumentID })
            let text = query.question + " " + target.title
            for offset in modes.indices {
                let mode = modes[(index + offset) % modes.count]
                samples += try measureRetrievalCell(
                    mode: mode, query: query, text: text, target: target, dataset: dataset,
                    modelURL: modelURL, directory: directory, encoder: encoder
                )
            }
        }
        let report = RetrievalAblationReport(
            schemaVersion: 1, dataset: dataset,
            configuration: [
                "scope": "retrieval only; no LLM generation, OCR, UI registration, or expert evaluation",
                "environment": "simulator_not_device_evidence",
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "processorCount": String(ProcessInfo.processInfo.processorCount),
                "modes": "keyword,semantic,hybrid",
                "query": "question + current document title",
                "retrieval": "320-character chunks,64 overlap,3 hits,2 chunks/document,cosine>0.30",
                "semantic": "E5 cosine only; no lexical score, exact-case bonus, or keyword fallback",
                "hybrid": "unchanged keyword + E5 RRF=60 with existing exact-case policy",
                "provider_cold": "fresh provider/model/vector cache per query/mode; one first search; OS file cache not cleared",
                "warm_passages_uncached_query": "same provider after first search; evict only query vector before each of 3 repeats",
                "order": "query order; mode order rotated by query index; cold then 3 warm repetitions per cell",
                "timing": "synchronous retriever wall time; includes per-request chunking; no task dispatch or LLM generation",
                "quality": "provisional document gold; P@3 fixed denominator; Recall/MRR undefined without gold",
                "llamaSwiftRevision": "7c03da71ca6adeae39fa37484d5cdf9d46779529"
            ], samples: samples
        )
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        XCTAssertEqual(samples.count, 36)
        print("RETRIEVAL_ABLATION_FINISHED \(directory.path)")
    }

    private func measureRetrievalCell(mode: RAGRetrievalMode, query: RAGEvaluationQuery, text: String,
                                     target: RAGDocument, dataset: RAGEvaluationDataset, modelURL: URL,
                                     directory: URL, encoder: JSONEncoder) throws -> [RetrievalAblationSample] {
        let provider = GGUFEmbeddingProvider(modelURL: modelURL)
        let retriever = RAGRetriever(provider: provider)
        var samples: [RetrievalAblationSample] = []
        for index in 0...3 {
            let phase = index == 0 ? "provider_cold" : "warm_passages_uncached_query"
            if index > 0 && mode != .keyword { try provider.clearCachedQuery(text) }
            let start = ProcessInfo.processInfo.systemUptime
            let search = try retriever.retrieve(query: text, target: target, documents: dataset.documents, mode: mode)
            let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(search.effectiveMode, mode)
            XCTAssertFalse(search.hits.contains { $0.chunk.documentID == target.id })
            if mode != .keyword {
                XCTAssertEqual(search.semanticScoredChunkCount, search.chunkCount)
                XCTAssertEqual(search.semanticModelIdentity["sha256"],
                               "1629184be879a108e16cceef62f7a0fedfff4eefb81cd734d646f8f404b85cdc")
                XCTAssertEqual(search.semanticModelIdentity["warmBeforeSearch"], index == 0 ? "false" : "true")
                if index > 0 {
                    XCTAssertEqual(search.semanticModelIdentity["vectorCacheMisses"], "1")
                    XCTAssertEqual(search.semanticModelIdentity["vectorCacheHits"], String(search.chunkCount))
                }
            }
            let sample = RetrievalAblationSample(
                queryID: query.id, phase: phase, repetition: max(1, index), queryText: text,
                durationMS: duration, search: search,
                relevance: try .calculate(hits: search.hits, relevant: query.relevantDocumentIDs)
            )
            samples.append(sample)
            let file = directory.appendingPathComponent("\(query.id)-\(mode.rawValue)-\(phase)-\(sample.repetition).json")
            try encoder.encode(sample).write(to: file, options: .atomic)
            print("RETRIEVAL_ABLATION_SAMPLE query=\(query.id) mode=\(mode.rawValue) phase=\(phase) repeat=\(sample.repetition) ms=\(duration)")
        }
        return samples
    }
}

private struct RetrievalAblationReport: Encodable {
    let schemaVersion: Int
    let dataset: RAGEvaluationDataset
    let configuration: [String: String]
    let samples: [RetrievalAblationSample]
}

private struct RetrievalAblationSample: Encodable {
    let queryID: String
    let phase: String
    let repetition: Int
    let queryText: String
    let durationMS: Double
    let search: RAGSearchResult
    let relevance: RAGRelevanceMetrics
}

private struct CosineObservation: Encodable {
    let queryID: String
    let chunk: RAGChunk
    let cosine: Double?
}
