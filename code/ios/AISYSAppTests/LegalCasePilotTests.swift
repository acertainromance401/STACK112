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
            for mode in RAGRetrievalMode.allCases {
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
}

private struct CosineObservation: Encodable {
    let queryID: String
    let chunk: RAGChunk
    let cosine: Double?
}
