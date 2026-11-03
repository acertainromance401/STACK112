import Foundation
import Darwin
import OSLog
import CryptoKit

struct RAGMemoryMeasurement: Codable {
    let beforeMB: Double?
    let afterMB: Double?
    let sampledPeakMB: Double?
    let sampleCount: Int
    let intervalMS: Int
    let error: String?
}

@MainActor
private final class RAGMemorySampler {
    private var task: Task<Void, Never>?
    private var samples: [Double] = []
    private var failure: String?
    private let logger = Logger(subsystem: "com.acertainromance401.aisys", category: "RAGMemory")

    func start() {
        sample()
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
                if !Task.isCancelled { sample() }
            }
        }
    }

    func stop() -> RAGMemoryMeasurement {
        task?.cancel()
        task = nil
        sample()
        return RAGMemoryMeasurement(
            beforeMB: samples.first, afterMB: samples.last, sampledPeakMB: samples.max(),
            sampleCount: samples.count, intervalMS: 50, error: failure
        )
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            failure = "task_info 실패: \(status)"
            logger.error("Memory sampling failed: \(status)")
            return
        }
        samples.append(Double(info.phys_footprint) / 1_048_576)
    }
}

struct RAGHumanReview: Codable {
    let reviewer: String
    let supportedClaims: Int
    let totalClaims: Int
    let reviewedAt: Date
}

struct RAGRunRecord: Encodable, Identifiable {
    let id: UUID
    let createdAt: Date
    let question: String
    let targetDocumentID: String
    let targetFingerprint: String
    let task: RAGAnalysisTask
    let corpusFingerprints: [String: String]
    let search: RAGSearchResult
    let evidence: [RAGEvidence]
    let generation: RAGGenerationTrace?
    let claims: [RAGClaim]
    let quizDraft: RAGQuizDraft?
    let failureReason: String?
    let retrievalMS: Double
    let modelPreparationMS: Double
    let totalMS: Double
    let memory: RAGMemoryMeasurement
    let environment: String
    let osVersion: String
    let deviceIdentifier: String
    let modelWasReady: Bool
    var humanReview: RAGHumanReview?

    var outputSuccess: Bool {
        failureReason == nil && generation?.failureReason == nil && !claims.isEmpty
            && claims.allSatisfy { $0.unknownCitationIDs.isEmpty }
    }

    var basicGroundingPassRate: Double? {
        guard !claims.isEmpty else { return nil }
        return Double(claims.filter(\.passesBasicChecks).count) / Double(claims.count)
    }

    mutating func review(reviewer: String, supportedClaims: Int) throws {
        guard !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !claims.isEmpty, (0...claims.count).contains(supportedClaims) else {
            throw RAGError.invalidInput("검수자와 유효한 근거 지지 문장 수가 필요합니다.")
        }
        humanReview = RAGHumanReview(
            reviewer: reviewer, supportedClaims: supportedClaims, totalClaims: claims.count, reviewedAt: Date()
        )
    }
}

struct RAGRunExport: Encodable {
    let run: RAGRunRecord
    let outputSuccess: Bool
    let basicGroundingProxy: Double?
    let outputSHA256: String?

    init(run: RAGRunRecord) {
        self.run = run
        outputSuccess = run.outputSuccess
        basicGroundingProxy = run.basicGroundingPassRate
        outputSHA256 = run.generation.map {
            SHA256.hash(data: Data($0.output.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

@MainActor
final class RAGResearchService {
    private let store: LocalCaseStore
    private let llm: LLMService
    private let retriever: RAGRetriever
    private let logger = Logger(subsystem: "com.acertainromance401.aisys", category: "RAGResearch")

    init(store: LocalCaseStore = .shared, llm: LLMService? = nil, retriever: RAGRetriever = RAGRetriever()) {
        self.store = store
        self.llm = llm ?? .shared
        self.retriever = retriever
    }

    func run(target: RAGDocument, question: String, mode: RAGRetrievalMode, task: RAGAnalysisTask = .analysis,
             documents: [RAGDocument]? = nil) async throws -> RAGRunRecord {
        guard !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RAGError.invalidInput("질문과 분석할 판례 원문이 필요합니다.")
        }
        let corpus = documents ?? store.snapshot().documents
        guard Set(corpus.map(\.id)).count == corpus.count else {
            throw RAGError.invalidInput("코퍼스 문서 ID가 중복되었습니다.")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let memory = RAGMemorySampler()
        memory.start()
        var stopped = false
        defer { if !stopped { _ = memory.stop() } }
        let query = question + " " + target.title
        let retriever = self.retriever
        let retrieval = Task.detached(priority: .userInitiated) {
            try retriever.retrieve(query: query, target: target, documents: corpus, mode: mode)
        }
        let search = try await withTaskCancellationHandler {
            try await retrieval.value
        } onCancel: { retrieval.cancel() }
        try Task.checkCancellation()
        let retrievalMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let currentChunks = try RAGChunker.chunks(for: target)
        let currentCorpus = currentChunks.map {
            APICase(id: $0.id, caseNumber: $0.caseNumber, caseName: $0.title, courtName: "", subject: target.subject,
                    issueSummary: $0.text, holdingSummary: nil, examPoints: nil, sourceUrl: $0.sourceURL)
        }
        let currentID = LocalCaseSearchEngine.search(query: question, in: currentCorpus, limit: 1).first?.id
        guard let current = currentChunks.first(where: { $0.id == currentID }) ?? currentChunks.first else {
            throw RAGError.invalidInput("현재 판례에서 검색 가능한 청크를 만들지 못했습니다.")
        }
        var evidence = [RAGEvidence(id: "E0", chunk: current)]
        evidence += search.hits.prefix(2).enumerated().map { RAGEvidence(id: "E\($0.offset + 1)", chunk: $0.element.chunk) }
        let wasReady = llm.state == .ready && !llm.isUsingFallbackEngine
        let preparationStart = ProcessInfo.processInfo.systemUptime
        if case .error = llm.state { await llm.load() }
        else { await llm.loadModelIfNeeded() }
        let preparationMS = (ProcessInfo.processInfo.systemUptime - preparationStart) * 1000
        var trace: RAGGenerationTrace?
        var claims: [RAGClaim] = []
        var quiz: RAGQuizDraft?
        var failure: String?
        do {
            try Task.checkCancellation()
            let generated = try await llm.generateRAGAnswer(question: question, evidence: evidence, task: task)
            trace = generated
            evidence = generated.evidence
            if let error = generated.failureReason {
                failure = error
            } else {
                claims = try RAGGrounding.assess(generated.output, evidence: evidence)
                if task == .oxDraft { quiz = try RAGQuizDraft.parse(claims) }
                if claims.contains(where: { !$0.unknownCitationIDs.isEmpty }) {
                    failure = "생성 결과가 제공하지 않은 근거 ID를 인용했습니다."
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = error.localizedDescription
            logger.error("RAG analysis failed: \(error.localizedDescription, privacy: .public)")
        }
        let measurement = memory.stop()
        stopped = true
        var system = utsname()
        uname(&system)
        let machineSize = MemoryLayout.size(ofValue: system.machine)
        let device = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
        #if targetEnvironment(simulator)
        let environment = "simulator_not_device_evidence"
        #else
        let environment = "physical_device"
        #endif
        return RAGRunRecord(
            id: UUID(), createdAt: Date(), question: question, targetDocumentID: target.id,
            targetFingerprint: target.fingerprint, task: task,
            corpusFingerprints: Dictionary(uniqueKeysWithValues: corpus.map { ($0.id, $0.fingerprint) }),
            search: search, evidence: evidence, generation: trace, claims: claims, quizDraft: quiz, failureReason: failure,
            retrievalMS: retrievalMS, modelPreparationMS: preparationMS,
            totalMS: (ProcessInfo.processInfo.systemUptime - start) * 1000,
            memory: measurement, environment: environment, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceIdentifier: device, modelWasReady: wasReady
        )
    }

    func modelFingerprint() async throws -> String? {
        guard let path = llm.selectedModelPath else { return nil }
        let work = Task.detached {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }
}

struct RAGEvaluationQuery: Codable, Identifiable {
    let id: String
    let targetDocumentID: String
    let question: String
    let relevantDocumentIDs: [String]
}

struct RAGEvaluationDataset: Codable {
    let schemaVersion: Int
    let id: String
    let kind: String
    let provenance: String
    let annotator: String
    let documents: [RAGDocument]
    let queries: [RAGEvaluationQuery]

    func validate() throws {
        let ids = Set(documents.map(\.id))
        let caseNumbers = documents.compactMap { LocalCaseSearchEngine.normalizedCaseNumber($0.caseNumber) }
        guard schemaVersion == 1, !id.isEmpty, ["synthetic", "real"].contains(kind),
              !provenance.isEmpty, !annotator.isEmpty, !documents.isEmpty, !queries.isEmpty,
              ids.count == documents.count, Set(queries.map(\.id)).count == queries.count,
              Set(caseNumbers).count == caseNumbers.count,
              documents.allSatisfy({ !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              queries.allSatisfy({ query in
                  !query.id.isEmpty && !query.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ids.contains(query.targetDocumentID)
                    && Set(query.relevantDocumentIDs).count == query.relevantDocumentIDs.count
                    && query.relevantDocumentIDs.allSatisfy { ids.contains($0) && $0 != query.targetDocumentID }
              }) else {
            throw RAGError.invalidInput("평가셋 형식, 출처·검수자, 중복 ID 또는 정답 문서 연결을 확인해 주세요.")
        }
    }

    static func bundledSynthetic() throws -> RAGEvaluationDataset {
        guard let url = Bundle.main.url(forResource: "rag_synthetic_v1", withExtension: "json") else {
            throw RAGError.unavailable("합성 평가셋 리소스가 없습니다.")
        }
        let dataset = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try dataset.validate()
        return dataset
    }
}

struct RAGRelevanceMetrics: Codable {
    let precisionAtK: Double
    let recallAtK: Double?
    let reciprocalRank: Double?
    let noRelevantDocumentCorrect: Bool?
    let evaluatedDocumentIDs: [String]

    static func calculate(hits: [RAGHit], relevant: [String], k: Int = 3) throws -> RAGRelevanceMetrics {
        guard k > 0 else { throw RAGError.invalidInput("관련성 평가의 k는 양수여야 합니다.") }
        var seen = Set<String>()
        let ids = hits.map(\.chunk.documentID).filter { seen.insert($0).inserted }.prefix(k)
        let gold = Set(relevant)
        let correct = ids.filter { gold.contains($0) }.count
        return RAGRelevanceMetrics(
            precisionAtK: Double(correct) / Double(k),
            recallAtK: gold.isEmpty ? nil : Double(correct) / Double(gold.count),
            reciprocalRank: gold.isEmpty ? nil : ids.firstIndex(where: { gold.contains($0) }).map { 1 / Double($0 + 1) } ?? 0,
            noRelevantDocumentCorrect: gold.isEmpty ? ids.isEmpty : nil, evaluatedDocumentIDs: Array(ids)
        )
    }
}

struct RAGEvaluationSample: Encodable, Identifiable {
    let queryID: String
    let repetition: Int
    let relevance: RAGRelevanceMetrics
    var run: RAGRunRecord
    let outputSuccess: Bool
    let basicGroundingProxy: Double?
    let outputSHA256: String?
    var id: UUID { run.id }

    init(queryID: String, repetition: Int, relevance: RAGRelevanceMetrics, run: RAGRunRecord) {
        self.queryID = queryID
        self.repetition = repetition
        self.relevance = relevance
        self.run = run
        let export = RAGRunExport(run: run)
        outputSuccess = export.outputSuccess
        basicGroundingProxy = export.basicGroundingProxy
        outputSHA256 = export.outputSHA256
    }
}

struct RAGEvaluationSummary: Codable {
    let mode: RAGRetrievalMode
    let sampleCount: Int
    let effectiveModeMatchCount: Int
    let meanPrecisionAt3: Double?
    let meanRecallAt3: Double?
    let mrrAt3: Double?
    let basicGroundingProxy: Double?
    let humanGroundingRate: Double?
    let reviewedRunCount: Int
    let inferenceMedianMS: Double?
    let inferenceP95MS: Double?
    let sampledPeakProcessMB: Double?
    let outputSuccessRate: Double?
}

struct RAGEvaluationReport: Encodable {
    let schemaVersion: Int
    let dataset: RAGEvaluationDataset
    let modelSHA256: String?
    let configuration: [String: String]
    var samples: [RAGEvaluationSample]

    var outputSuccessRate: Double? {
        samples.isEmpty ? nil : Double(samples.filter { $0.run.outputSuccess }.count) / Double(samples.count)
    }

    var summaries: [RAGEvaluationSummary] {
        RAGRetrievalMode.allCases.map { mode in
            let group = samples.filter { $0.run.search.requestedMode == mode }
            let matched = group.filter { $0.run.search.effectiveMode == mode }
            let reviews = matched.compactMap(\.run.humanReview)
            let reviewedClaims = reviews.reduce(0) { $0 + $1.totalClaims }
            let physical = matched.filter { $0.run.environment == "physical_device" }
            let times = physical.compactMap(\.run.generation).filter { $0.attempts > 0 }.map(\.inferenceMS).sorted()
            return RAGEvaluationSummary(
                mode: mode, sampleCount: group.count, effectiveModeMatchCount: matched.count,
                meanPrecisionAt3: mean(matched.map(\.relevance.precisionAtK)),
                meanRecallAt3: mean(matched.compactMap(\.relevance.recallAtK)),
                mrrAt3: mean(matched.compactMap(\.relevance.reciprocalRank)),
                basicGroundingProxy: mean(matched.compactMap(\.run.basicGroundingPassRate)),
                humanGroundingRate: reviewedClaims == 0 ? nil : Double(reviews.reduce(0) { $0 + $1.supportedClaims }) / Double(reviewedClaims),
                reviewedRunCount: reviews.count,
                inferenceMedianMS: times.isEmpty ? nil : times[(times.count - 1) / 2],
                inferenceP95MS: times.isEmpty ? nil : times[max(0, Int(ceil(Double(times.count) * 0.95)) - 1)],
                sampledPeakProcessMB: physical.compactMap(\.run.memory.sampledPeakMB).max(),
                outputSuccessRate: group.isEmpty ? nil : Double(group.filter { $0.run.outputSuccess }.count) / Double(group.count)
            )
        }
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, dataset, modelSHA256, configuration, samples, summaries }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(dataset, forKey: .dataset)
        try container.encodeIfPresent(modelSHA256, forKey: .modelSHA256)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(samples, forKey: .samples)
        try container.encode(summaries, forKey: .summaries)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

@MainActor
enum RAGEvaluator {
    static func run(dataset: RAGEvaluationDataset, repetitions: Int = 1,
                    modes: [RAGRetrievalMode] = RAGRetrievalMode.allCases,
                    service: RAGResearchService, progress: (Int, Int) -> Void) async throws -> RAGEvaluationReport {
        try dataset.validate()
        guard (1...20).contains(repetitions) else { throw RAGError.invalidInput("반복 횟수는 1~20회여야 합니다.") }
        guard !modes.isEmpty, Set(modes).count == modes.count else {
            throw RAGError.invalidInput("평가 모드를 중복 없이 한 개 이상 선택해 주세요.")
        }
        var samples: [RAGEvaluationSample] = []
        let total = repetitions * dataset.queries.count * modes.count
        for repetition in 1...repetitions {
            for query in dataset.queries {
                guard let target = dataset.documents.first(where: { $0.id == query.targetDocumentID }) else {
                    throw RAGError.invalidInput("평가 대상 문서를 찾을 수 없습니다.")
                }
                // 순서에 따른 편향을 줄이고 첫 로드 여부는 실행별로 별도 기록한다.
                let offset = (repetition - 1) % modes.count
                for index in modes.indices {
                    try Task.checkCancellation()
                    let mode = modes[(index + offset) % modes.count]
                    let run = try await service.run(target: target, question: query.question, mode: mode, documents: dataset.documents)
                    samples.append(RAGEvaluationSample(
                        queryID: query.id, repetition: repetition,
                        relevance: try .calculate(hits: run.search.hits, relevant: query.relevantDocumentIDs), run: run
                    ))
                    progress(samples.count, total)
                }
            }
        }
        return RAGEvaluationReport(
            schemaVersion: 1, dataset: dataset, modelSHA256: try await service.modelFingerprint(),
            configuration: [
                "chunkSizeCharacters": "320", "chunkOverlapCharacters": "64", "retrievalChunkK": "3",
                "relevanceDocumentK": "3", "rrfConstant": "60", "semanticCosineThreshold": "0.30",
                "semanticModel": "intfloat/multilingual-e5-base Q8_0; SentencePiece; mean pooling; L2; query:/passage: prefixes",
                "embeddingCache": "512 in-memory text-hash vectors; hits/misses and cold/warm status recorded per retrieval",
                "modes": modes.map(\.rawValue).joined(separator: ","), "repetitions": String(repetitions),
                "pipelineVersion": "stack112-research-rag-v1",
                "llamaSwiftRevision": "7c03da71ca6adeae39fa37484d5cdf9d46779529",
                "groundingMetric": "lexical/numeric/quote proxy; not legal entailment",
                "memory": "process phys_footprint, sampled every 50ms; not exact peak or model-only memory",
                "inferenceTime": "sum of primary generate calls, including failed attempts; excludes load/recovery",
                "cache": "research path bypasses legacy summary and RAG caches"
            ], samples: samples
        )
    }
}
