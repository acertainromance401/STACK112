import Foundation
import OSLog

// MARK: - LLM State

enum LLMState: Equatable {
    case idle
    case loading(progress: Double)
    case ready
    case inferring
    case error(String)
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
    case notReady
    case outputParsingFailed

    var errorDescription: String? {
        switch self {
        case .notReady: return "LLM 엔진이 준비되지 않았습니다."
        case .outputParsingFailed:  return "LLM 출력 파싱에 실패했습니다."
        }
    }
}

// MARK: - LLMService
//
// 역할: MLX 없이 로컬 요약/퀴즈 생성을 제공합니다.
// 추후 llama.cpp/CoreML 엔진으로 교체할 때 인터페이스는 그대로 유지합니다.

@MainActor
final class LLMService: ObservableObject {
    static let shared = LLMService()
    private let logger = Logger(subsystem: "com.acertainromance401.aisys", category: "LLMService")
    private let primaryLoadAttempts = 3
    private let primaryGenerateAttempts = 2
    private let oneLineLimit = 140
    private let keyIssueLimit = 220
    private let rulingLimit = 260
    private let examLimit = 180

    @Published private(set) var state: LLMState = .idle
    @Published private(set) var loadProgress: Double = 0
    @Published private(set) var activeEngineName: String = "준비 전"
    @Published private(set) var isUsingFallbackEngine = true
    @Published private(set) var lastLoadMessage: String?
    @Published private(set) var selectedModelSource: String?
    @Published private(set) var selectedModelPath: String?
    @Published private(set) var bundleModelPath: String?
    @Published private(set) var documentsModelPath: String?
    @Published private(set) var modelSelectionReason: String?
    @Published private(set) var ignoreDocumentsModel = false

    private let primaryEngine: LocalLLMEngine
    private let fallbackEngine: LocalLLMEngine
    private var useFallback = true

    private init(
        primaryEngine: LocalLLMEngine = LlamaCppEngine(),
        fallbackEngine: LocalLLMEngine = RuleBasedLocalEngine()
    ) {
        self.primaryEngine = primaryEngine
        self.fallbackEngine = fallbackEngine
    }

    // MARK: - Model Loading

    func loadModelIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    func load() async {
        state = .loading(progress: 0)
        lastLoadMessage = nil
        selectedModelSource = nil
        selectedModelPath = nil
        bundleModelPath = nil
        documentsModelPath = nil
        modelSelectionReason = nil
        for step in [0.2, 0.45, 0.7] {
            loadProgress = step
            state = .loading(progress: step)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        do {
            try await activatePrimaryEngine()
        } catch {
            await activateFallback(reason: error.localizedDescription)
        }

        loadProgress = 1.0
        state = .ready
    }

    func setIgnoreDocumentsModel(_ ignore: Bool) async {
        guard ignoreDocumentsModel != ignore else { return }
        ignoreDocumentsModel = ignore
        await primaryEngine.resetModel()
        await load()
    }

    // MARK: - Inference

    /// 판례 데이터를 받아 LLM 요약(LLMSummary)을 생성합니다.
    func summarize(caseItem: APICase) async throws -> LLMSummary? {
        guard case .ready = state else { throw LLMError.notReady }

        state = .inferring
        defer {
            if case .inferring = state { state = .ready }
        }

        // APICase의 판례 필드를 PromptTemplates.summarize 형식으로 직렬화합니다.
        // 여기서 만든 문자열이 그대로 llama 엔진의 입력 프롬프트가 됩니다.
        let prompt = LLMPromptTemplate.summarize(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            issue: caseItem.issueSummary ?? "",
            holding: caseItem.holdingSummary ?? "",
            examPoints: caseItem.examPoints ?? ""
        )

        let rawOutput: String
        do {
            rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 256, purpose: "summarize")
        } catch {
            let fallbackRaw = buildSummaryOutput(caseItem: caseItem)
            return LLMSummary(rawOutput: fallbackRaw)
        }
        if let summary = LLMSummary(rawOutput: rawOutput) {
            return postprocessSummary(summary, caseItem: caseItem)
        }

        let normalizedOutput = normalizeSummaryOutput(rawOutput, caseItem: caseItem)
        if let summary = LLMSummary(rawOutput: normalizedOutput) {
            return postprocessSummary(summary, caseItem: caseItem)
        }

        // 모델 출력 형식이 달라도 UX가 깨지지 않도록 안전 폴백
        let fallbackRaw = buildSummaryOutput(caseItem: caseItem)
        return LLMSummary(rawOutput: fallbackRaw)
    }

    /// 판례 데이터를 받아 객관식 퀴즈를 생성합니다.
    func generateQuiz(caseItem: APICase, summary: LLMSummary?) async throws -> QuizQuestion {
        guard case .ready = state else { throw LLMError.notReady }

        state = .inferring
        defer {
            if case .inferring = state { state = .ready }
        }

        let issue = summary?.keyIssue ?? caseItem.issueSummary ?? ""
        let holding = summary?.rulingPoint ?? caseItem.holdingSummary ?? ""
        let examTakeaway = summary?.examTakeaway ?? caseItem.examPoints ?? ""
        let evidenceBlock = """
        [1] \(caseItem.caseNumber) \(caseItem.caseName)
        쟁점: \(issue)
        결론: \(holding)
        시험포인트: \(examTakeaway)
        """
        let prompt = LLMPromptTemplate.quiz(
            question: "해당 판례의 핵심 쟁점과 시험 포인트를 점검하는 객관식 문제를 만들어라.",
            evidenceBlock: evidenceBlock
        )

        do {
            // 객관식도 요약과 동일하게 prompt -> engine.generate -> 파서 순서로 흐릅니다.
            let rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 320, purpose: "quiz")
            if let question = QuizQuestion(
                rawOutput: rawOutput,
                title: caseItem.caseName,
                fallbackKeywords: [caseItem.caseNumber, caseItem.subject].filter { !$0.isEmpty }
            ) {
                return question
            }
        } catch {
            return buildFallbackQuiz(caseItem: caseItem, summary: summary)
        }

        return buildFallbackQuiz(caseItem: caseItem, summary: summary)
    }

    /// 두 판례를 비교 분석합니다.
    func compare(question: String, cases: [APICase]) async throws -> String {
        guard case .ready = state else { throw LLMError.notReady }

        state = .inferring
        defer {
            if case .inferring = state { state = .ready }
        }

        let evidenceBlock = cases.enumerated().map { idx, c in
            "[\(idx + 1)] \(c.caseNumber) \(c.caseName)\n쟁점: \(c.issueSummary ?? "")\n결론: \(c.holdingSummary ?? "")"
        }.joined(separator: "\n\n")
        let prompt = LLMPromptTemplate.compare(question: question, evidenceBlock: evidenceBlock)

        do {
            return try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 320, purpose: "compare")
        } catch {
            return buildComparisonOutput(question: question, cases: cases)
        }
    }

    // MARK: - Private

    private func activatePrimaryEngine() async throws {
        var lastError: Error?

        for attempt in 1...primaryLoadAttempts {
            do {
                applyPrimaryEnginePreferences()
                await primaryEngine.resetModel()
                // 1순위는 실제 llama.cpp 엔진입니다. 성공하면 이후 generate 호출이 GGUF 모델로 들어갑니다.
                try await primaryEngine.loadModel()
                useFallback = false
                isUsingFallbackEngine = false
                activeEngineName = primaryEngine.name
                updateModelDiagnosticsFromPrimaryEngine()
                lastLoadMessage = attempt == 1
                    ? "GGUF 모델 로드 성공: \(primaryEngine.name) / source=\(selectedModelSource ?? "알 수 없음")"
                    : "GGUF 모델 로드 성공: \(primaryEngine.name) (재시도 \(attempt)회차) / source=\(selectedModelSource ?? "알 수 없음")"
                logger.info("Active engine: \(self.activeEngineName, privacy: .public)")
                return
            } catch {
                lastError = error
                updateModelDiagnosticsFromPrimaryEngine()
                logger.error("Primary engine load attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < primaryLoadAttempts {
                    lastLoadMessage = "llama.cpp 재시도 중: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
        }

        throw lastError ?? LLMError.notReady
    }

    private func activateFallback(reason: String) async {
        try? await fallbackEngine.loadModel()
        useFallback = true
        isUsingFallbackEngine = true
        activeEngineName = fallbackEngine.name
        lastLoadMessage = "fallback 전환: \(reason)"
        logger.error("Fallback engine activated: \(self.activeEngineName, privacy: .public), reason: \(reason, privacy: .public)")
    }

    private func updateModelDiagnosticsFromPrimaryEngine() {
        guard let llamaEngine = primaryEngine as? LlamaCppEngine else { return }
        selectedModelSource = llamaEngine.modelResolution.selectedSource?.rawValue
        selectedModelPath = llamaEngine.modelResolution.selectedURL?.path
        bundleModelPath = llamaEngine.modelResolution.bundleURL?.path
        documentsModelPath = llamaEngine.modelResolution.documentsURL?.path
        modelSelectionReason = llamaEngine.modelResolution.selectionReason
    }

    private func applyPrimaryEnginePreferences() {
        guard let llamaEngine = primaryEngine as? LlamaCppEngine else { return }
        llamaEngine.ignoreDocumentsModel = ignoreDocumentsModel
    }

    private func generateUsingBestAvailableEngine(prompt: String, maxTokens: Int, purpose: String) async throws -> String {
        // 모바일 환경에서 프롬프트 길이가 길수록 CPU 사용량 급증 - 미리 제한
        let maxPromptLength = 1200
        let truncatedPrompt = prompt.count > maxPromptLength 
            ? prompt.prefix(maxPromptLength) + "..." 
            : prompt
        
        if useFallback {
            logger.debug("\(purpose, privacy: .public) using fallback engine: \(self.activeEngineName, privacy: .public)")
            return try await fallbackEngine.generate(prompt: String(truncatedPrompt), maxTokens: maxTokens)
        }

        var lastError: Error?
        for attempt in 1...primaryGenerateAttempts {
            do {
                logger.debug("\(purpose, privacy: .public) using primary engine: \(self.activeEngineName, privacy: .public), attempt \(attempt)")
                return try await primaryEngine.generate(prompt: String(truncatedPrompt), maxTokens: maxTokens)
            } catch {
                lastError = error
                logger.error("Primary generate failure for \(purpose, privacy: .public), attempt \(attempt): \(error.localizedDescription, privacy: .public)")
                if attempt < primaryGenerateAttempts {
                    try? await recoverPrimaryEngine(after: error, purpose: purpose)
                }
            }
        }

        await activateFallback(reason: "\(purpose) 생성 실패: \(lastError?.localizedDescription ?? "알 수 없는 오류")")
        return try await fallbackEngine.generate(prompt: String(truncatedPrompt), maxTokens: maxTokens)
    }

    private func recoverPrimaryEngine(after error: Error, purpose: String) async throws {
        lastLoadMessage = "llama.cpp 복구 중: \(purpose) / \(error.localizedDescription)"
        await primaryEngine.resetModel()
        try? await Task.sleep(nanoseconds: 120_000_000)
        try await primaryEngine.loadModel()
        useFallback = false
        isUsingFallbackEngine = false
        activeEngineName = primaryEngine.name
        lastLoadMessage = "llama.cpp 복구 성공: \(purpose) 재시도"
        logger.info("Primary engine recovered for \(purpose, privacy: .public)")
    }

    private func normalizeSummaryOutput(_ rawOutput: String, caseItem: APICase) -> String {
        let cleaned = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else {
            return buildSummaryOutput(caseItem: caseItem)
        }

        let oneLine = cleaned.first ?? caseItem.caseName
        let detail = cleaned.dropFirst().joined(separator: " ")
        let keyIssue = caseItem.issueSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruling = detail.isEmpty ? (caseItem.holdingSummary ?? "판결 결론 정보가 부족합니다") : detail
        let exam = caseItem.examPoints?.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        - one_line_summary: \(oneLine)
        - key_issue: \((keyIssue?.isEmpty == false) ? keyIssue! : "핵심 쟁점 정보가 부족합니다")
        - ruling_point: \(ruling)
        - exam_takeaway: \((exam?.isEmpty == false) ? exam! : "시험 포인트 정보가 부족합니다")
        """
    }

    private func postprocessSummary(_ summary: LLMSummary, caseItem: APICase) -> LLMSummary? {
        var oneLine = shrink(summary.oneLineSummary, limit: oneLineLimit)
        var keyIssue = shrink(summary.keyIssue, limit: keyIssueLimit)
        var ruling = shrink(summary.rulingPoint, limit: rulingLimit)
        var exam = shrink(summary.examTakeaway, limit: examLimit)

        // 필드 간 중복이 크면 사례 메타 정보로 대체해 카드별 의미를 분리합니다.
        if isTooSimilar(oneLine, keyIssue) {
            keyIssue = shrink(caseItem.issueSummary ?? keyIssue, limit: keyIssueLimit)
        }
        if isTooSimilar(keyIssue, ruling) {
            ruling = shrink(caseItem.holdingSummary ?? ruling, limit: rulingLimit)
        }
        if isTooSimilar(exam, keyIssue) || isTooSimilar(exam, ruling) {
            let fallbackExam = caseItem.examPoints?.trimmingCharacters(in: .whitespacesAndNewlines)
            exam = shrink(fallbackExam?.isEmpty == false ? fallbackExam! : exam, limit: examLimit)
        }

        return LLMSummary(rawOutput: canonicalSummaryRaw(oneLine: oneLine, keyIssue: keyIssue, ruling: ruling, exam: exam))
    }

    private func shrink(_ text: String, limit: Int) -> String {
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard cleaned.count > limit else {
            return cleaned
        }

        let idx = cleaned.index(cleaned.startIndex, offsetBy: limit)
        var clipped = String(cleaned[..<idx])
        if let lastPunctuation = clipped.lastIndex(where: { ".!?".contains($0) }) {
            clipped = String(clipped[...lastPunctuation])
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isTooSimilar(_ a: String, _ b: String) -> Bool {
        let na = normalizeForCompare(a)
        let nb = normalizeForCompare(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        if na.contains(nb) || nb.contains(na) { return true }

        let sa = Set(na.split(separator: " "))
        let sb = Set(nb.split(separator: " "))
        guard !sa.isEmpty && !sb.isEmpty else { return false }
        let common = sa.intersection(sb).count
        let denom = max(sa.count, sb.count)
        return Double(common) / Double(denom) >= 0.7
    }

    private func normalizeForCompare(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^0-9a-zA-Z가-힣\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonicalSummaryRaw(oneLine: String, keyIssue: String, ruling: String, exam: String) -> String {
        """
        - one_line_summary: \(oneLine)
        - key_issue: \(keyIssue)
        - ruling_point: \(ruling)
        - exam_takeaway: \(exam)
        """
    }

    private func buildSummaryOutput(caseItem: APICase) -> String {
        // 줄바꿈 제거: LLMSummary 정규식이 단일 줄만 캡처하므로 sanitize 필요
        func sanitize(_ s: String) -> String {
            s.components(separatedBy: .newlines)
             .map { $0.trimmingCharacters(in: .whitespaces) }
             .filter { !$0.isEmpty }
             .joined(separator: " ")
             .prefix(200)
             .description
        }
        let name = sanitize(caseItem.caseName)
        let issue = sanitize(caseItem.issueSummary ?? "주요 쟁점 정보가 부족합니다")
        let holding = sanitize(caseItem.holdingSummary ?? "판결 결론 정보가 부족합니다")
        let examPoint = sanitize(caseItem.examPoints ?? "시험 포인트 정보가 부족합니다")

        return """
        - one_line_summary: \(name)은(는) \(issue) 중심으로 판단한 판례입니다.
        - key_issue: \(issue)
        - ruling_point: \(holding)
        - exam_takeaway: \(examPoint)
        """
    }

    private func buildComparisonOutput(question: String, cases: [APICase]) -> String {
        if cases.isEmpty {
            return "비교할 판례 데이터가 없습니다."
        }

        let list = cases.map { c in
            "- \(c.caseNumber) \(c.caseName): \(c.issueSummary ?? "쟁점 정보 없음")"
        }.joined(separator: "\n")

        return """
        질문: \(question)
        엔진: \(activeEngineName)

        공통/차이 비교 초안:
        \(list)

        정리: 사건번호별 핵심 쟁점을 기준으로 공통점과 차이점을 확인하세요.
        """
    }

    private func buildFallbackQuiz(caseItem: APICase, summary: LLMSummary?) -> QuizQuestion {
        let issue = summary?.keyIssue ?? caseItem.issueSummary ?? "쟁점 정보 없음"
        let holding = summary?.rulingPoint ?? caseItem.holdingSummary ?? "결론 정보 없음"
        let examTakeaway = summary?.examTakeaway ?? caseItem.examPoints ?? "시험 포인트 정보 없음"
        let wrongOption = "쟁점과 무관하게 결론만 외워도 동일한 판단이 가능하다"

        return QuizQuestion(
            title: caseItem.caseName,
            prompt: "다음 중 \(caseItem.caseName) 판례 학습 포인트로 가장 부적절한 것을 고르시오.",
            options: [issue, holding, examTakeaway, wrongOption],
            correctIndex: 3,
            explanation: "해당 판례 학습은 쟁점, 결론, 시험 포인트를 함께 이해해야 하며 결론만 암기하는 접근은 부적절합니다.",
            keywords: [caseItem.caseNumber, caseItem.subject].filter { !$0.isEmpty }
        )
    }

    // MARK: - OX Quiz Generation

    /// IR 파이프라인이 추출한 keySentences + keywords를 기반으로 OX 퀴즈를 생성합니다.
    /// - Parameters:
    ///   - caseItem: 대상 판례
    ///   - keySentences: ir_pipeline.extract_key_sentences() 결과 (백엔드 /ir/extract 응답)
    ///   - keywords: ir_pipeline.extract_keywords() 결과
    ///   - count: 생성할 문항 수 (기본 3개)
    func generateOXQuiz(
        caseItem: APICase,
        keySentences: String,
        keywords: [String],
        count: Int = 3
    ) async throws -> [OXQuizQuestion] {
        guard case .ready = state else { throw LLMError.notReady }

        state = .inferring
        defer {
            if case .inferring = state { state = .ready }
        }

        let compactSentences = keySentences
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: " ")

        let compactKeywords = Array(NSOrderedSet(array: keywords.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }))
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }

        let prompt = LLMPromptTemplate.oxQuiz(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            keySentences: compactSentences.isEmpty ? (caseItem.issueSummary ?? "") : compactSentences,
            keywords: compactKeywords.isEmpty
                ? [caseItem.subject, caseItem.issueSummary ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                : compactKeywords.prefix(8).joined(separator: ", "),
            count: count
        )

        do {
            // OX 퀴즈는 IR 추출 결과를 먼저 압축한 뒤 프롬프트에 넣고 생성합니다.
            let rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 512, purpose: "ox_quiz")
            let parsed = OXQuizQuestion.parseList(rawOutput: rawOutput)
            if !parsed.isEmpty { return parsed }
        } catch {}

        // 폴백: keySentences의 첫 문장들을 직접 OX 문항으로 구성
        return buildFallbackOXQuiz(caseItem: caseItem, keySentences: keySentences, count: count)
    }

    private func buildFallbackOXQuiz(
        caseItem: APICase,
        keySentences: String,
        count: Int
    ) -> [OXQuizQuestion] {
        // 의미있는 문장만 추출 (10자 이상, URL/숫자열 제외)
        let sentences = keySentences
            .components(separatedBy: CharacterSet(charactersIn: "。."))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { s in
                s.count > 10 &&
                !s.contains("portal.scourt") &&
                !s.contains("http") &&
                !s.allSatisfy({ $0.isNumber || $0 == ":" })
            }

        let fallbackSentences: [String]
        if sentences.isEmpty {
            fallbackSentences = [
                caseItem.issueSummary ?? "\(caseItem.caseName)은(는) 핵심 쟁점이 있는 판례다",
                caseItem.holdingSummary ?? "법원은 해당 사안에 대해 명확한 판단을 내렸다",
                caseItem.examPoints ?? "이 판례는 시험에 자주 출제되는 중요 판례다",
            ]
        } else {
            fallbackSentences = sentences
        }

        let caseNum = caseItem.caseNumber

        // O 문항: 원문 그대로 (정답), X 문항: 핵심어를 반대로 표현
        return fallbackSentences.prefix(count).enumerated().map { idx, sentence in
            let isOAnswer = idx % 2 == 0
            if isOAnswer {
                return OXQuizQuestion(
                    statement: String(sentence.prefix(100)),
                    answer: true,
                    explanation: "[\(caseNum)] 판결에서 확인된 내용입니다."
                )
            } else {
                // X 문항: 문장 앞에 "~이 아니다" 형태로 변형
                let xStatement = sentence.prefix(80) + "고 볼 수 없다"
                return OXQuizQuestion(
                    statement: String(xStatement.prefix(100)),
                    answer: false,
                    explanation: "[\(caseNum)] 판결의 취지와 반대되는 진술입니다. 원문을 확인하세요."
                )
            }
        }
    }

    private var activeEngine: LocalLLMEngine {
        // 실제 추론 호출 직전 어느 엔진을 탈지 결정하는 단일 분기점입니다.
        useFallback ? fallbackEngine : primaryEngine
    }
}
