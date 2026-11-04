import CryptoKit
import XCTest
@testable import AISYSApp

final class SummaryPreservationEvaluationTests: XCTestCase {
    func testSentenceRolesKeepOriginalRangesAndExcludeBibliography() throws {
        let source = fixture()
        let retriever = RAGRetriever(semanticScorer: { _, chunks in chunks.map { _ in 0.8 } })
        for mode in [RAGRetrievalMode.keyword, .semantic, .hybrid] {
            let plan = try SummaryEvidencePlanner.plan(document: source, mode: mode, retriever: retriever)
            XCTAssertEqual(plan.evidence.map(\.role), SummaryEvidencePlanner.Role.allCases)
            XCTAssertEqual(plan.searches.count, 3)
            for evidence in plan.evidence {
                let chunk = evidence.chunk
                let range = NSRange(location: chunk.startUTF16, length: chunk.endUTF16 - chunk.startUTF16)
                XCTAssertEqual((source.text as NSString).substring(with: range), chunk.text)
                XCTAssertFalse(chunk.text.contains("메타데이터전용"))
                XCTAssertTrue(chunk.text.hasSuffix("."))
            }
            XCTAssertEqual(plan.evidence.last?.chunk.text, "원심판결을 파기하고 환송한다.")
            XCTAssertEqual(plan.evidence.first?.chunk.text, "부과된 의무는 조건 없이 변경할 수 없다.")
        }
    }

    func testPlannerRejectsMissingSectionsAndUnavailableSemantic() throws {
        let missing = RAGDocument(caseItem: APICase(
            id: "missing", caseNumber: "", caseName: "", courtName: "", subject: "",
            issueSummary: nil, holdingSummary: nil, examPoints: nil, sourceUrl: nil),
            rawText: "원문 영역 없이 작성된 글입니다.")
        let unavailable = RAGRetriever(semanticScorer: { _, chunks in chunks.map { _ in nil } })
        XCTAssertThrowsError(try SummaryEvidencePlanner.plan(document: missing, mode: .keyword, retriever: unavailable))
        XCTAssertThrowsError(try SummaryEvidencePlanner.plan(document: fixture(), mode: .semantic, retriever: unavailable))
        XCTAssertThrowsError(try SummaryEvidencePlanner.plan(document: fixture(), mode: .hybrid, retriever: unavailable))
        XCTAssertThrowsError(try SummaryEvidencePlanner.plan(document: fixture(), mode: .currentOnly, retriever: unavailable))
    }

    func testPromptPreservesNegativeEvidenceAndExplicitRoles() throws {
        let source = fixture()
        let plan = try SummaryEvidencePlanner.plan(
            document: source, mode: .semantic,
            retriever: RAGRetriever(semanticScorer: { _, chunks in chunks.map { _ in 0.8 } }))
        let prompt = SummaryEvidencePlanner.prompt(document: source, plan: plan)
        XCTAssertTrue(prompt.contains("조건 없이 변경할 수 없다."))
        for role in SummaryEvidencePlanner.Role.allCases {
            XCTAssertTrue(prompt.contains("[\(role.label)]"))
            XCTAssertTrue(prompt.contains("\(role.label):"))
        }
        XCTAssertFalse(prompt.contains("메타데이터전용"))
    }

    @MainActor
    func testRunShortPreservationPilot() async throws {
        let datasetURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "family_law_retrieval_v1", withExtension: "json"))
        let dataset = try JSONDecoder().decode(RAGEvaluationDataset.self, from: Data(contentsOf: datasetURL))
        try dataset.validate()
        let document = try XCTUnwrap(dataset.documents.first { $0.id == "sc-2026eu552" })
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("summary-preservation-pilot-v1", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw RAGError.unavailable("기존 짧은 실험의 결과를 덮어쓸 수 없습니다.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let engine = LlamaCppEngine(evaluationContextTokens: 8192)
        let store = LocalCaseStore(seed: [])
        let llm = LLMService(primaryEngine: engine, caseStore: store)
        let loadStart = ProcessInfo.processInfo.systemUptime
        await llm.load()
        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        guard !llm.isUsingFallbackEngine else { throw RAGError.unavailable("실제 Llama 엔진이 필요합니다.") }
        let fingerprint = try await RAGResearchService(store: store, llm: llm).modelFingerprint()
        let modelSHA = try XCTUnwrap(fingerprint)
        XCTAssertEqual(modelSHA, "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83")
        let embeddingURL = try XCTUnwrap(Bundle.main.url(forResource: GGUFEmbeddingProvider.fileName, withExtension: nil))
        let provider = GGUFEmbeddingProvider(modelURL: embeddingURL)
        let retriever = RAGRetriever(provider: provider)
        var conditions: [PreservationCondition] = []
        for mode in [RAGRetrievalMode.keyword, .semantic, .hybrid] {
            let start = ProcessInfo.processInfo.systemUptime
            let plan = try SummaryEvidencePlanner.plan(document: document, mode: mode, retriever: retriever)
            let selectionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let prompt = SummaryEvidencePlanner.prompt(document: document, plan: plan)
            let wrapped = llm.wrapForLlama3Instruct(userPrompt: prompt, purpose: "summarize")
            try engine.validatePrompt(wrapped, maxTokens: 128)
            let tokens = try engine.promptTokenCount(wrapped)
            guard tokens <= 1536 else { throw RAGError.invalidInput("짧은 실험의 입력 상한 1536토큰을 초과했습니다: \(tokens)") }
            conditions.append(PreservationCondition(
                mode: mode, plan: plan, prompt: prompt, wrappedPrompt: wrapped,
                promptSHA256: Self.digest(Data(wrapped.utf8)), promptTokenCount: tokens, selectionMS: selectionMS))
            print("PRESERVATION_INPUT mode=\(mode.rawValue) tokens=\(tokens) selectionMS=\(selectionMS)")
        }
        let manifest = PreservationManifest(
            schemaVersion: 1, document: document, sourceSHA256: document.fingerprint, modelSHA256: modelSHA,
            contextTokens: 8192, outputTokens: 128, seed: 42, generationModelLoadMS: loadMS,
            environment: "simulator_not_device_evidence", osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            providerPolicy: "One provider shared in K/S/H selection order; H reuses E5 passage/query vectors. Not independent latency observations.",
            conditions: conditions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        print("PRESERVATION_MANIFEST_FINISHED \(directory.path)")
        var samples: [PreservationSample] = []
        for condition in conditions {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await engine.generateForEvaluation(
                prompt: condition.wrappedPrompt, maxTokens: 128, sampling: .seeded(42))
            let generationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(result.samplerSeed, 42)
            XCTAssertEqual(result.promptTokenCount, condition.promptTokenCount)
            XCTAssertEqual(result.originalPromptTokenCount, condition.promptTokenCount)
            XCTAssertEqual(result.contextTokens, 8192)
            XCTAssertEqual(result.outputTokenLimit, 128)
            let sample = PreservationSample(
                id: "\(condition.mode.rawValue)-seed42", mode: condition.mode, order: samples.count + 1,
                manifestSHA256: Self.digest(manifestData), generationMS: generationMS, result: result)
            try encoder.encode(sample).write(
                to: directory.appendingPathComponent("\(sample.id).json"), options: .atomic)
            samples.append(sample)
            print("PRESERVATION_SAMPLE id=\(sample.id) generationMS=\(generationMS) tokens=\(result.generatedTokenCount)")
            print("PRESERVATION_OUTPUT \(result.text)")
        }
        try encoder.encode(PreservationReport(schemaVersion: 1, manifest: manifest, samples: samples))
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        XCTAssertEqual(samples.count, 3)
        print("PRESERVATION_FINISHED \(directory.path)")
    }

    private func fixture() -> RAGDocument {
        let item = APICase(id: "fixture", caseNumber: "2025도123", caseName: "조건", courtName: "법원", subject: "테스트",
                          issueSummary: nil, holdingSummary: nil, examPoints: nil, sourceUrl: nil)
        return RAGDocument(caseItem: item, rawText: """
        【참조판례】
        메타데이터전용 2020도99.
        【판결요지】
        부과된 의무는 조건 없이 변경할 수 없다.
        【주 문】
        원심판결을 파기하고 환송한다.
        【이 유】
        당사자에게 새로운 조건의 의무를 부과하였다.
        법원은 이 조건의 부과가 허용되지 않는다고 판단하였다.
        """)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct PreservationCondition: Codable {
    let mode: RAGRetrievalMode
    let plan: SummaryEvidencePlanner.Plan
    let prompt: String
    let wrappedPrompt: String
    let promptSHA256: String
    let promptTokenCount: Int
    let selectionMS: Double
}

private struct PreservationManifest: Codable {
    let schemaVersion: Int
    let document: RAGDocument
    let sourceSHA256: String
    let modelSHA256: String
    let contextTokens: Int
    let outputTokens: Int
    let seed: UInt32
    let generationModelLoadMS: Double
    let environment: String
    let osVersion: String
    let providerPolicy: String
    let conditions: [PreservationCondition]
}

private struct PreservationSample: Codable {
    let id: String
    let mode: RAGRetrievalMode
    let order: Int
    let manifestSHA256: String
    let generationMS: Double
    let result: LlamaCppEngine.EvaluationOutput
}

private struct PreservationReport: Codable {
    let schemaVersion: Int
    let manifest: PreservationManifest
    let samples: [PreservationSample]
}
