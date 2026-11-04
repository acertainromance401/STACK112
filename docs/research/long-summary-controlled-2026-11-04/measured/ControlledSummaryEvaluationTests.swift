import CryptoKit
import XCTest
@testable import AISYSApp

final class ControlledSummaryEvaluationTests: XCTestCase {
    private let contextTokens: UInt32 = 8192
    private let outputTokens = 128

    func testSummaryTemplateDefaultsAndUncappedFields() {
        let text = String(repeating: "source evidence ", count: 100)
        let capped = LLMPromptTemplate.summarize(caseNumber: "C", caseName: text, issue: text, holding: text, examPoints: text)
        let explicit = LLMPromptTemplate.summarize(caseNumber: "C", caseName: text, issue: text, holding: text, examPoints: text, fieldLimit: 96)
        let uncapped = LLMPromptTemplate.summarize(caseNumber: "C", caseName: text, issue: text, holding: text, examPoints: text, fieldLimit: nil)
        XCTAssertEqual(capped, explicit)
        XCTAssertFalse(capped.contains(text))
        XCTAssertTrue(uncapped.contains("사건명: \(text)\n쟁점: \(text)\n판결: \(text)\n시험포인트: \(text)"))
    }

    func testEvaluationRequiresOptIn() async {
        do {
            _ = try await LlamaCppEngine().generateForEvaluation(prompt: "test", maxTokens: 128, sampling: .greedy)
            XCTFail("기본 앱 엔진에서 평가 설정을 허용하면 안 됩니다.")
        } catch LocalLLMEngineError.runtimeUnavailable(let reason) {
            XCTAssertTrue(reason.contains("평가 전용"))
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }
    }

    @MainActor
    func testPreflightControlledSummaryPrompts() async throws {
        let datasetURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "family_law_retrieval_v1", withExtension: "json"))
        let dataset = try JSONDecoder().decode(RAGEvaluationDataset.self, from: Data(contentsOf: datasetURL))
        try dataset.validate()
        let document = try XCTUnwrap(dataset.documents.first { $0.id == "sc-2026eu552" })
        let engine = LlamaCppEngine(evaluationContextTokens: contextTokens)
        let store = LocalCaseStore(seed: [])
        let llm = LLMService(primaryEngine: engine, caseStore: store)
        let loadStart = ProcessInfo.processInfo.systemUptime
        await llm.load()
        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        guard !llm.isUsingFallbackEngine else { throw RAGError.unavailable("실제 Llama 엔진이 필요합니다.") }
        let embeddingURL = try XCTUnwrap(Bundle.main.url(forResource: GGUFEmbeddingProvider.fileName, withExtension: nil))
        let parsed = JudgmentParser.parse(document.text)
        XCTAssertFalse(parsed.issues.isEmpty)
        XCTAssertFalse(parsed.holdings.isEmpty)
        let queries = ["핵심 쟁점 판시사항", "판단 이유 법리 원칙 예외", "주문 결론 파기 환송 기각"]
        var conditions: [ControlledSummaryCondition] = []
        for mode in ["fields", "keyword", "semantic", "hybrid"] {
            let start = ProcessInfo.processInfo.systemUptime
            var searches: [RAGSearchResult] = []
            var fields = [parsed.issues.joined(separator: "\n"), parsed.holdings.map(\.text).joined(separator: "\n"), parsed.statutesRaw ?? ""]
            if mode != "fields" {
                let retrievalMode = try XCTUnwrap(RAGRetrievalMode(rawValue: mode))
                let retriever = RAGRetriever(provider: GGUFEmbeddingProvider(modelURL: embeddingURL))
                fields = try queries.map { query in
                    let search = try retriever.retrieveWithin(document: document, query: query, mode: retrievalMode)
                    XCTAssertEqual(search.effectiveMode, retrievalMode)
                    XCTAssertTrue(search.warnings.isEmpty)
                    if retrievalMode != .keyword { XCTAssertEqual(search.semanticScoredChunkCount, search.chunkCount) }
                    searches.append(search)
                    return try XCTUnwrap(search.hits.first).chunk.text
                }
            }
            let selectionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let input = APICase(id: document.id, caseNumber: document.caseNumber, caseName: document.title,
                                courtName: "대법원", subject: document.subject, issueSummary: fields[0],
                                holdingSummary: fields[1], examPoints: fields[2], sourceUrl: document.sourceURL)
            for policy in ["capped", "uncapped"] {
                let prompt: String
                if policy == "capped" {
                    prompt = try llm.prepareSummaryPrompt(caseItem: input, references: [])
                    XCTAssertEqual(prompt, LLMPromptTemplate.summarize(
                        caseNumber: input.caseNumber, caseName: input.caseName, issue: fields[0],
                        holding: fields[1], examPoints: fields[2], fieldLimit: 96))
                } else {
                    prompt = LLMPromptTemplate.summarize(
                        caseNumber: input.caseNumber, caseName: input.caseName, issue: fields[0],
                        holding: fields[1], examPoints: fields[2], fieldLimit: nil)
                    for field in fields where !field.isEmpty { XCTAssertTrue(prompt.contains(field)) }
                }
                let wrapped = llm.wrapForLlama3Instruct(userPrompt: prompt, purpose: "summarize")
                try engine.validatePrompt(wrapped, maxTokens: outputTokens)
                let tokenCount = try engine.promptTokenCount(wrapped)
                XCTAssertLessThanOrEqual(tokenCount + outputTokens + 8, Int(contextTokens))
                conditions.append(ControlledSummaryCondition(
                    id: "\(policy)-\(mode)", policy: policy, mode: mode, input: input,
                    searches: searches, prompt: prompt, wrappedPrompt: wrapped,
                    promptSHA256: Self.digest(Data(wrapped.utf8)), promptTokenCount: tokenCount, selectionMS: selectionMS))
                print("CONTROLLED_PREFLIGHT policy=\(policy) mode=\(mode) characters=\(wrapped.count) tokens=\(tokenCount)")
            }
        }
        let oversized = String(repeating: " token", count: Int(contextTokens) + 1)
        XCTAssertThrowsError(try engine.validatePrompt(oversized, maxTokens: outputTokens))
        do {
            _ = try await engine.generateForEvaluation(prompt: oversized, maxTokens: outputTokens, sampling: .greedy)
            XCTFail("평가 입력은 조용히 잘라내면 안 됩니다.")
        } catch LocalLLMEngineError.promptTooLong {
        }
        do {
            _ = try await engine.generateForEvaluation(prompt: "test", maxTokens: outputTokens, sampling: .seeded(UInt32.max))
            XCTFail("자동 seed는 평가에 허용하면 안 됩니다.")
        } catch LocalLLMEngineError.runtimeUnavailable {
        }
        let fingerprint = try await RAGResearchService(store: store, llm: llm).modelFingerprint()
        let modelSHA = try XCTUnwrap(fingerprint)
        let manifest = ControlledSummaryManifest(schemaVersion: 1, environment: "simulator_not_device_evidence",
            document: document, sourceSHA256: document.fingerprint, modelSHA256: modelSHA,
            contextTokens: Int(contextTokens), outputTokens: outputTokens, generationModelLoadMS: loadMS,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, facetQueries: queries,
            conditions: conditions)
        let directory = try exportDirectory()
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            throw RAGError.unavailable("기존 사전검증 manifest를 덮어쓸 수 없습니다.")
        }
        try write(manifest, to: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(conditions.count, 8)
        print("CONTROLLED_PREFLIGHT_FINISHED \(directory.path)")
    }

    @MainActor
    func testRunControlledSummaryComparison() async throws {
        let directory = try exportDirectory()
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(ControlledSummaryManifest.self, from: manifestData)
        XCTAssertEqual(manifest.contextTokens, Int(contextTokens))
        XCTAssertEqual(manifest.outputTokens, outputTokens)
        XCTAssertEqual(manifest.conditions.count, 8)
        let engine = LlamaCppEngine(evaluationContextTokens: contextTokens)
        let store = LocalCaseStore(seed: [])
        let llm = LLMService(primaryEngine: engine, caseStore: store)
        let loadStart = ProcessInfo.processInfo.systemUptime
        await llm.load()
        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        guard !llm.isUsingFallbackEngine else { throw RAGError.unavailable("실제 Llama 엔진이 필요합니다.") }
        let fingerprint = try await RAGResearchService(store: store, llm: llm).modelFingerprint()
        guard fingerprint == manifest.modelSHA256 else { throw RAGError.unavailable("사전 검증 후 생성 모델이 변경되었습니다.") }
        let seeds: [UInt32?] = [nil, nil, 42, 43, 44]
        var samples: [ControlledSummarySample] = []
        for round in seeds.indices {
            for offset in manifest.conditions.indices {
                let condition = manifest.conditions[(offset + round) % manifest.conditions.count]
                let seed = seeds[round]
                let decoder = seed == nil ? "greedy" : "seeded"
                let repetition = seed == nil ? round + 1 : 1
                let suffix = seed.map { "seed\($0)" } ?? "greedy\(repetition)"
                let id = "\(condition.id)-\(suffix)"
                let checkpoint = directory.appendingPathComponent("\(id).json")
                guard !FileManager.default.fileExists(atPath: checkpoint.path) else {
                    throw RAGError.unavailable("기존 출력 덮어쓰기는 허용하지 않습니다: \(id)")
                }
                XCTAssertEqual(Self.digest(Data(condition.wrappedPrompt.utf8)), condition.promptSHA256)
                try engine.validatePrompt(condition.wrappedPrompt, maxTokens: outputTokens)
                let start = ProcessInfo.processInfo.systemUptime
                let output = try await engine.generateForEvaluation(
                    prompt: condition.wrappedPrompt, maxTokens: outputTokens,
                    sampling: seed.map { .seeded($0) } ?? .greedy)
                let generationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let sample = ControlledSummarySample(
                    id: id, order: samples.count + 1, conditionID: condition.id, decoder: decoder,
                    seed: seed, repetition: repetition, manifestSHA256: Self.digest(manifestData),
                    generationMS: generationMS, result: output, formatParsed: LLMSummary(rawOutput: output.text) != nil)
                try write(sample, to: checkpoint)
                samples.append(sample)
                XCTAssertEqual(output.originalPromptTokenCount, condition.promptTokenCount)
                XCTAssertEqual(output.promptTokenCount, condition.promptTokenCount)
                XCTAssertEqual(output.contextTokens, Int(contextTokens))
                XCTAssertEqual(output.outputTokenLimit, outputTokens)
                XCTAssertEqual(output.samplerSeed, seed)
                print("CONTROLLED_SUMMARY_SAMPLE id=\(id) order=\(sample.order) tokens=\(output.promptTokenCount) generationMS=\(generationMS)")
                print("CONTROLLED_SUMMARY_OUTPUT \(output.text)")
            }
        }
        try write(ControlledSummaryReport(schemaVersion: 1, manifest: manifest,
                                         generationModelLoadMS: loadMS, samples: samples),
                  to: directory.appendingPathComponent("report.json"))
        XCTAssertEqual(samples.count, 40)
        print("CONTROLLED_SUMMARY_FINISHED \(directory.path)")
    }

    private func exportDirectory() throws -> URL {
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("long-summary-controlled-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ControlledSummaryCondition: Codable {
    let id: String
    let policy: String
    let mode: String
    let input: APICase
    let searches: [RAGSearchResult]
    let prompt: String
    let wrappedPrompt: String
    let promptSHA256: String
    let promptTokenCount: Int
    let selectionMS: Double
}

private struct ControlledSummaryManifest: Codable {
    let schemaVersion: Int
    let environment: String
    let document: RAGDocument
    let sourceSHA256: String
    let modelSHA256: String
    let contextTokens: Int
    let outputTokens: Int
    let generationModelLoadMS: Double
    let osVersion: String
    let facetQueries: [String]
    let conditions: [ControlledSummaryCondition]
}

private struct ControlledSummarySample: Codable {
    let id: String
    let order: Int
    let conditionID: String
    let decoder: String
    let seed: UInt32?
    let repetition: Int
    let manifestSHA256: String
    let generationMS: Double
    let result: LlamaCppEngine.EvaluationOutput
    let formatParsed: Bool
}

private struct ControlledSummaryReport: Codable {
    let schemaVersion: Int
    let manifest: ControlledSummaryManifest
    let generationModelLoadMS: Double
    let samples: [ControlledSummarySample]
}
