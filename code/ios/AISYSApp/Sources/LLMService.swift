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
    private let lowMemoryPromptLimit = 720
    private let normalPromptLimit = 960
    private let lowMemoryTokenCap = 160
    private let normalTokenCap = 220

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
    @Published private(set) var ignoreDocumentsModel = true

    private let primaryEngine: LocalLLMEngine
    private let fallbackEngine: LocalLLMEngine
    private var useFallback = true

    // MARK: - Caches (똑같은 판례 재진입 시 LLM 재호출 회피)
    // LLMService 가 @MainActor 이므로 단순 Dictionary 로 안전. 최대 32건 LRU-lite.
    private var summaryCache: [String: LLMSummary] = [:]
    private var oxCache: [String: [OXQuizQuestion]] = [:]
    private var ragCache: [String: String] = [:]
    private let cacheCapacity = 32
    /// 약점 키워드(개인화 hint) 공급 클로저. RootTabView에서 ReviewStore 와 바인딩.
    var weakKeywordsProvider: (() -> [String])? = nil

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

        // 캐시 히트 — 동일 case 재진입이면 즉시 반환
        let cacheKey = "sum:\(caseItem.caseNumber)"
        if let cached = summaryCache[cacheKey] {
            return cached
        }

        state = .inferring
        defer {
            if case .inferring = state { state = .ready }
        }

        let ragEvidence = await buildRAGEvidence(caseItem: caseItem)

        // APICase의 판례 필드를 PromptTemplates.summarize 형식으로 직렬화합니다.
        // 여기서 만든 문자열이 그대로 llama 엔진의 입력 프롬프트가 됩니다.
        let prompt = LLMPromptTemplate.summarize(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            issue: caseItem.issueSummary ?? "",
            holding: caseItem.holdingSummary ?? "",
            examPoints: caseItem.examPoints ?? "",
            ragEvidence: ragEvidence
        )

        // 백엔드 grounded 분기는 v1.0에서 제거됨 — 모든 추론은 온디바이스 우선.
        // 로컬 1B 출력이 실패하면 RuleBasedLocalEngine + buildSummaryOutput 폴백으로 처리한다.

        let rawOutput: String
        do {
            rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 240, purpose: "summarize")
        } catch {
            let fallbackRaw = buildSummaryOutput(caseItem: caseItem)
            return LLMSummary(rawOutput: fallbackRaw)
        }
        if let summary = LLMSummary(rawOutput: rawOutput) {
            if let post = postprocessSummary(summary, caseItem: caseItem) {
                cacheSummary(post, forKey: cacheKey)
                return post
            }
        }

        let normalizedOutput = normalizeSummaryOutput(rawOutput, caseItem: caseItem)
        if let summary = LLMSummary(rawOutput: normalizedOutput) {
            if let post = postprocessSummary(summary, caseItem: caseItem) {
                cacheSummary(post, forKey: cacheKey)
                return post
            }
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
            let rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 220, purpose: "quiz")
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

        // v1.0: 서버 grounded 분기 제거. 로컬 엔진 실패 시 룰 기반 요약으로 폴백.
        do {
            return try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 220, purpose: "compare")
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
        // 모바일 환경에서 컨텍스트/토큰을 보수적으로 제한
        let maxPromptLength = isLowMemoryDevice() ? lowMemoryPromptLimit : normalPromptLimit
        let truncatedPrompt = prompt.count > maxPromptLength 
            ? prompt.prefix(maxPromptLength) + "..." 
            : prompt
        let effectiveMaxTokens = min(maxTokens, isLowMemoryDevice() ? lowMemoryTokenCap : normalTokenCap)
        
        if useFallback {
            logger.debug("\(purpose, privacy: .public) using fallback engine: \(self.activeEngineName, privacy: .public)")
            // Rule-based 엔진은 chat template을 이해하지 못하므로 raw prompt 그대로 전달
            return try await fallbackEngine.generate(prompt: String(truncatedPrompt), maxTokens: effectiveMaxTokens)
        }

        // Llama-3.2-Instruct GGUF는 chat template 적용 시 instruct 토큰을 인식해
        // template echo / 반복 / 형식 어긋남이 크게 줄어듭니다.
        let wrappedPrompt = wrapForLlama3Instruct(userPrompt: String(truncatedPrompt), purpose: purpose)

        var lastError: Error?
        for attempt in 1...primaryGenerateAttempts {
            do {
                logger.debug("\(purpose, privacy: .public) using primary engine: \(self.activeEngineName, privacy: .public), attempt \(attempt)")
                return try await primaryEngine.generate(prompt: wrappedPrompt, maxTokens: effectiveMaxTokens)
            } catch {
                lastError = error
                logger.error("Primary generate failure for \(purpose, privacy: .public), attempt \(attempt): \(error.localizedDescription, privacy: .public)")
                if attempt < primaryGenerateAttempts {
                    try? await recoverPrimaryEngine(after: error, purpose: purpose)
                }
            }
        }

        await activateFallback(reason: "\(purpose) 생성 실패: \(lastError?.localizedDescription ?? "알 수 없는 오류")")
        return try await fallbackEngine.generate(prompt: String(truncatedPrompt), maxTokens: effectiveMaxTokens)
    }

    /// Llama-3.2-Instruct 공식 chat template로 프롬프트를 감쌉니다.
    /// 시스템 메시지로 강의 대체 금지/근거 기반 출력 규칙을 고정합니다.
    private func wrapForLlama3Instruct(userPrompt: String, purpose: String) -> String {
        let systemMessage: String
        switch purpose {
        case "summarize":
            systemMessage = "당신은 한국 판례 복습 보조이다. 강의 대체가 아닌 시험 복습용 짧은 한국어 출력만 작성한다. 제공된 근거 외 사실을 만들지 않는다. 출력 형식(- one_line_summary: ... 등)을 정확히 지킨다."
        case "ox_quiz":
            systemMessage = "당신은 한국 경찰/공무원 시험 OX 문항 출제자이다. 강의 해설은 쓰지 말고 한 글자/숫자 함정을 활용한 짧은 OX 문항만 만든다. O와 X를 반드시 섞고 출력 형식(--- 구분)을 지킨다."
        case "quiz":
            systemMessage = "당신은 한국 시험 객관식 출제자이다. 근거에서만 정답을 도출하고 모호한 보기를 만들지 않는다. 출력 형식을 정확히 지킨다."
        case "compare":
            systemMessage = "당신은 한국 판례 비교 보조이다. 근거가 없는 단정은 하지 않고 사건번호로 인용한다. 강의식 확장 없이 공통점/차이점/시험 함정만 짧게 쓴다."
        default:
            systemMessage = "당신은 한국 법률 학습 보조이다. 근거 외 사실을 만들지 않으며 짧고 명확한 한국어로만 답한다."
        }

        return """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(systemMessage)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(userPrompt)<|eot_id|><|start_header_id|>assistant<|end_header_id|>


        """
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

        func hasKorean(_ text: String) -> Bool {
            text.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
        }

        func isScaffolding(_ line: String) -> Bool {
            let lower = line.lowercased()
            if lower.hasPrefix("[role") || lower.hasPrefix("[task") || lower.hasPrefix("[rules") || lower.hasPrefix("[evidence") || lower.hasPrefix("[output") {
                return true
            }
            if lower == "---" || lower.contains("outputformat") {
                return true
            }
            // Chained template keys: 3+ colons in a line = key chain like "- foo: - bar: - baz:"
            if lower.components(separatedBy: ":").count - 1 >= 3 {
                return true
            }
            // Prompt echo
            if lower.contains("please help") || lower.contains("## step") || lower.contains("analyze the given") {
                return true
            }
            let labels = [
                "one_line_summary:", "key_issue:", "ruling_point:", "exam_takeaway:",
                "holding_summary:", "issue_summary:", "exam_points:", "held:", "reason:",
                "한줄요약:", "핵심쟁점:", "결론:", "포인트:"
            ]
            if labels.contains(where: { lower == "- \($0)" || lower == $0 }) {
                return true
            }
            if lower.hasPrefix("case_number:") || lower.hasPrefix("case_name:") || lower.hasPrefix("사건번호:") || lower.hasPrefix("쟁점:") || lower.hasPrefix("판결:") {
                return true
            }
            return false
        }

        func stripLabelTokens(_ text: String) -> String {
            text
                .replacingOccurrences(
                    of: #"(?i)\b(one_line_summary|key_issue|ruling_point|exam_takeaway|holding_summary|issue_summary|exam_points|held|reason)\b\s*:"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"(한줄요약|핵심쟁점|결론|포인트)\s*:"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Only use lines that contain actual Korean content
        let semanticLines = cleaned
            .filter { !isScaffolding($0) && hasKorean($0) }
            .map(stripLabelTokens)
            .filter { !$0.isEmpty && $0.count >= 8 }

        // Always use caseItem fields for structured content — LLM output used only for oneLine hint
        let keyIssue = caseItem.issueSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruling = caseItem.holdingSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exam = caseItem.examPoints?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !semanticLines.isEmpty || keyIssue != nil else {
            return buildSummaryOutput(caseItem: caseItem)
        }

        // 1B 모델이 만든 첫 한 줄이 너무 짧거나 의미없으면 학습카드 스타일을 직접 합성한다.
        let llmHint = semanticLines.first ?? ""
        let composed = composeStudyCardOneLine(
            caseItem: caseItem,
            issueShort: keyIssue ?? "",
            holdingShort: ruling ?? ""
        )
        let oneLine: String
        if llmHint.count >= 24 && hasKoreanTerminal(llmHint) {
            // 모델 출력이 충분히 길고 종결어미가 있으면 그쪽을 우선 사용
            oneLine = shrink(llmHint, limit: oneLineLimit)
        } else {
            oneLine = composed
        }

        let finalKeyIssue = (keyIssue?.isEmpty == false)
            ? ensureKoreanTerminal(shrink(scrubResidualNoise(keyIssue!), limit: 130))
            : "핵심 쟁점 정보가 부족합니다."
        let finalRuling = (ruling?.isEmpty == false)
            ? ensureKoreanTerminal(shrink(scrubResidualNoise(ruling!), limit: 130))
            : "판결 결론 정보가 부족합니다."
        let finalExam = (exam?.isEmpty == false)
            ? ensureKoreanTerminal(shrink(exam!, limit: examLimit))
            : "시험 포인트 정보가 부족합니다."

        return """
        - one_line_summary: \(oneLine)
        - key_issue: \(finalKeyIssue)
        - ruling_point: \(finalRuling)
        - exam_takeaway: \(finalExam)
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
        // 줄바꿈 제거 + 종결어미 보정으로 카드에 어색하게 잘리지 않게 한다.
        func sanitize(_ s: String, limit: Int) -> String {
            var cleaned = s.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            // OCR 줄바꿈으로 조사·접속사로 시작하는 단편 보정
            let leading = ["는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "의 ", "에 ", "도 ", "와 ", "과 ", "로 ", "으로 "]
            for p in leading where cleaned.hasPrefix(p) {
                cleaned = String(cleaned.dropFirst(p.count))
                break
            }
            return smartTruncateKorean(cleaned, limit: limit)
        }
        let name = sanitize(caseItem.caseName, limit: 80)
        let issue = sanitize(caseItem.issueSummary ?? "주요 쟁점 정보가 부족하다.", limit: keyIssueLimit)
        let holding = sanitize(caseItem.holdingSummary ?? "판결 결론 정보가 부족하다.", limit: rulingLimit)
        let examPoint = sanitize(caseItem.examPoints ?? "시험 포인트 정보가 부족하다.", limit: examLimit)
        let oneLine = composeStudyCardOneLine(caseItem: caseItem, issueShort: issue, holdingShort: holding)

        return """
        - one_line_summary: \(oneLine)
        - key_issue: \(ensureKoreanTerminal(issue))
        - ruling_point: \(ensureKoreanTerminal(holding))
        - exam_takeaway: \(ensureKoreanTerminal(examPoint))
        """
    }

    /// 경찰고시 학습카드 스타일의 한 줄 요약 생성기.
    /// 형식: "[도메인] {사건명} 사건. {핵심 쟁점 짧게}에 관해 {결론 방향} 판단한 사례."
    /// 결론 방향이 없으면 마지막 절을 생략한다.
    private func composeStudyCardOneLine(caseItem: APICase, issueShort: String, holdingShort: String) -> String {
        // 1) 도메인 라벨 — caseItem.subject 앞부분에 "민사 ·", "형법 ·" 등 라벨이 들어와 있으면 그것을 사용
        let domainLabel: String = {
            let subject = caseItem.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if subject.contains("·") {
                let head = subject.components(separatedBy: "·").first ?? ""
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.count <= 4 { return h }
            }
            // subject 자체가 짧은 도메인 라벨 같으면 그대로
            if subject.count > 0 && subject.count <= 5 { return subject }
            return ""
        }()

        // 2) 사건명 정리 — 타임스탬프 형태(OCR-...) 면 사건번호로 대체
        var name = caseItem.caseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("OCR-") || name.isEmpty {
            name = caseItem.caseNumber
        }
        if name.count > 40 {
            name = String(name.prefix(40))
        }

        // 3) 쟁점 핵심구 추출 — "...여부" / "...에 관한 사건" 패턴이면 그 절만 떼어 사용
        let issueCore = extractIssueCore(issueShort)

        // 4) 결론 방향어 추출 — 위법/적법/포함/배제/유죄/무죄 등
        let verdict = extractVerdictPhrase(holdingShort)

        // 5) 조립
        var parts: [String] = []
        if !domainLabel.isEmpty {
            parts.append("[\(domainLabel)]")
        }
        if !name.isEmpty {
            parts.append("\(name) 사건.")
        }
        if !issueCore.isEmpty {
            if !verdict.isEmpty {
                parts.append("\(issueCore)에 관해 \(verdict) 판단한 사례.")
            } else {
                parts.append("\(issueCore)\(koreanObjectMarker(issueCore)) 다툰 판례.")
            }
        } else if !verdict.isEmpty {
            parts.append("\(verdict) 판단한 사례.")
        } else {
            parts.append("핵심 쟁점이 정리된 판례이다.")
        }
        let line = parts.joined(separator: " ")
        return smartTruncateKorean(line, limit: oneLineLimit)
    }

    /// LLMService 단계에서 한 번 더 OCR 잔재(닫히지 않은 [공YYYY..., 〉/〈, 잘못된 띄어쓰기)를 제거한다.
    /// OCRView의 stripBracketNoise를 통과하지 못한 케이스 대비 안전장치.
    private func scrubResidualNoise(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[[^\]]{1,80}\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\s*공\s*\d{2,4}.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[공보[^\]]*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "〉", with: " ")
        s = s.replacingOccurrences(of: "〈", with: " ")
        for pair in [("하 는", "하는"), ("되 는", "되는"), ("이 다", "이다"), ("한 다", "한다"),
                     ("된 다", "된다"), ("하 다", "하다"), ("있 다", "있다"), ("없 다", "없다")] {
            s = s.replacingOccurrences(of: pair.0, with: pair.1)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 쟁점 문장에서 핵심 명사구만 추출. "...의 ...여부" 패턴이면 "여부"까지 포함해서 반환.
    /// 반환된 구는 "...에 관해 Y 판단한 사례" 합성에 자연스럽게 끼워진다.
    private func extractIssueCore(_ issue: String) -> String {
        var s = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // 노이즈 잔재 제거 (학습카드 합성용)
        s = s.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"〉|〈"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        // 조사·접속사로 시작하는 OCR 단편이면 첫 토큰을 떼어내 자연스럽게 만든다.
        // 예) "는 손해의 범위에..." → "손해의 범위에..."
        let leadingParticles = ["는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "의 ", "에 ", "도 ", "와 ", "과 ", "로 ", "으로 "]
        for p in leadingParticles where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
            break
        }

        // 마커를 포함해 잘라내기 — 끝이 "...되는지" / "...여부" 형태가 되도록
        let markers = ["문제 된 사건", "문제된 사건", "여부", "되는지", "할 수 있는지", "해당하는지", "허용되는지"]
        for marker in markers {
            if let r = s.range(of: marker) {
                let head = String(s[s.startIndex..<r.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if head.count >= 8 && head.count <= 90 {
                    let cleaned = head.replacingOccurrences(of: #"^[\s,.;:\-]+"#, with: "", options: .regularExpression)
                    // "문제 된 사건"이 끝나는 경우 → "...이 문제 된" 만 남기는 게 자연스러움
                    if cleaned.hasSuffix("문제 된 사건") {
                        return String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if cleaned.hasSuffix("문제된 사건") {
                        return String(cleaned.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return cleaned
                }
            }
        }
        // 그 외엔 첫 70자 정도
        if s.count <= 70 { return s }
        let snippet = String(s.prefix(70))
        if let space = snippet.range(of: " ", options: .backwards) {
            return String(snippet[..<space.lowerBound])
        }
        return snippet
    }

    /// 결론 문장에서 결과 방향어만 추출 — "포함되지 않는다", "위법하다", "유죄로 본다" 등
    private func extractVerdictPhrase(_ holding: String) -> String {
        let candidates: [(String, String)] = [
            ("(적극)", "적극적으로"),
            ("(소극)", "소극적으로"),
            ("포함되지 않는다", "포함되지 않는다고"),
            ("포함된다", "포함된다고"),
            ("해당하지 않는다", "해당하지 않는다고"),
            ("해당한다", "해당한다고"),
            ("위법하다", "위법하다고"),
            ("적법하다", "적법하다고"),
            ("유죄", "유죄로"),
            ("무죄", "무죄로"),
            ("기각", "기각"),
            ("인용한다", "인용"),
            ("위반된다", "위반된다고"),
            ("허용되지 않는다", "허용되지 않는다고"),
            ("허용된다", "허용된다고"),
            ("한정위헌", "한정위헌으로"),
            ("헌법불합치", "헌법불합치로"),
            ("위헌", "위헌으로"),
            ("합헌", "합헌으로"),
            ("파기환송", "파기환송"),
            ("파기한다", "파기"),
            ("환송한다", "환송"),
            ("성립하지 않는다", "성립하지 않는다고"),
            ("성립한다", "성립한다고"),
            ("인정되지 않는다", "인정되지 않는다고"),
            ("인정된다", "인정된다고")
        ]
        for (needle, phrase) in candidates {
            if holding.contains(needle) {
                return phrase
            }
        }
        return ""
    }

    // MARK: - 1B Llama 보조 분류기/변형기

    /// 결론 문장의 결론 방향(verdict)을 1B 모델에 분류시킨다.
    /// 출력은 고정 라벨 한 개 ("위법" / "적법" / "유죄" / "무죄" / "기각" / "인용" / "한정위헌" / "위헌" / "합헌" / "파기환송" / "포함" / "배제" / "해당" / "비해당" / "기타")
    /// 실패하거나 라벨 외 출력이 나오면 빈 문자열 반환 → 호출부에서 룰베이스(extractVerdictPhrase)로 폴백.
    func classifyVerdictWithLLM(holding: String) async -> String {
        guard case .ready = state else { return "" }
        let body = holding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 6 else { return "" }
        let snippet = String(body.prefix(180))
        let prompt = """
        다음 한국 판례의 판결 결론을 한 단어 라벨로만 분류하라.
        후보 라벨: 위법, 적법, 유죄, 무죄, 기각, 인용, 한정위헌, 위헌, 합헌, 파기환송, 포함, 배제, 해당, 비해당, 기타
        결론: \(snippet)
        라벨(한 단어만 출력):
        """
        let labelMap: [(needle: String, phrase: String)] = [
            ("한정위헌", "한정위헌으로"), ("헌법불합치", "헌법불합치로"),
            ("파기환송", "파기환송"), ("위헌", "위헌으로"), ("합헌", "합헌으로"),
            ("위법", "위법하다고"), ("적법", "적법하다고"),
            ("유죄", "유죄로"), ("무죄", "무죄로"),
            ("기각", "기각"), ("인용", "인용"),
            ("포함", "포함된다고"), ("배제", "배제된다고"),
            ("비해당", "해당하지 않는다고"), ("해당", "해당한다고")
        ]
        do {
            let raw = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 8, purpose: "verdict_classify")
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 출력 첫 줄/첫 토큰만 검사
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            for entry in labelMap where firstLine.contains(entry.needle) {
                return entry.phrase
            }
        } catch {
            return ""
        }
        return ""
    }

    // MARK: - 경찰 시험 분류 트리 (계층적 LLM 분류기)

    /// 분류 트리: 과목 > 카테고리 > 세부유형
    /// 출처: police_exam_classification_tree.md
    private static let taxonomyTree: [(subject: String, categories: [(name: String, leaves: [String])])] = [
        ("형법", [
            ("재산범죄", ["절도", "강도", "사기", "횡령", "배임"]),
            ("인신범죄", ["살인", "과실치사", "상해", "폭행", "성범죄"]),
            ("위법성조각", ["정당방위", "긴급피난", "피해자승낙", "자구행위"]),
            ("범죄성립론", ["고의범", "과실범", "미수", "불능미수", "예비", "공동정범", "교사범"]),
            ("책임론", ["책임능력", "금지착오", "기대가능성"]),
            ("국가적법익", ["위증", "모해위증", "무고", "증거인멸", "공무집행방해"])
        ]),
        ("형사소송법", [
            ("체포·구속", ["현행범체포", "긴급체포", "영장체포", "구속"]),
            ("압수·수색", ["영장집행", "임의제출", "긴급압수", "별건압수"]),
            ("증거능력", ["위법수집증거배제", "전문법칙", "자백배제", "보강증거", "임의성"]),
            ("수사일반", ["임의수사", "강제처분", "함정수사", "수사준칙"])
        ]),
        ("헌법", [
            ("기본권", ["표현의자유", "직업의자유", "사생활의자유", "평등권", "신체의자유", "재산권", "행복추구권"]),
            ("위헌심사", ["위헌", "합헌", "한정위헌", "헌법불합치", "과잉금지"]),
            ("통치구조", ["국회", "행정부", "사법부", "헌법재판소"])
        ]),
        ("경찰학", [
            ("경찰작용", ["불심검문", "보호조치", "위험방지", "범죄예방", "직무집행"]),
            ("경찰조직", ["국가경찰", "자치경찰", "경찰위원회"]),
            ("징계·통제", ["징계", "소청심사", "정보공개"])
        ])
    ]

    /// 텍스트를 분류 트리로 계층 분류하여 "과목 > 카테고리 > 세부유형" 경로 반환.
    /// LLM 실패/타임아웃 시 단계별로 가장 그럴듯한 경로까지만 반환 (최소 과목 라벨은 항상 산출).
    func classifyByTaxonomy(text: String) async -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 8 else { return "" }
        let snippet = String(body.prefix(220))

        // Level 1: 과목 분류
        let subjects = Self.taxonomyTree.map { $0.subject }
        let subject = await classifyOneLevel(
            text: snippet,
            labels: subjects,
            examples: [
                ("피고인이 타인의 지갑을 절취한 사건", "형법"),
                ("수사기관이 영장 없이 압수한 증거의 효력", "형사소송법"),
                ("표현의 자유 제한이 헌법에 위반되는지 여부", "헌법"),
                ("경찰관 직무집행법상 불심검문의 적법 요건", "경찰학")
            ],
            ruleFallback: ruleClassifySubject(snippet)
        )
        guard !subject.isEmpty,
              let subjectEntry = Self.taxonomyTree.first(where: { $0.subject == subject }) else {
            return subject
        }

        // Level 2: 카테고리 분류
        let categories = subjectEntry.categories.map { $0.name }
        let category = await classifyOneLevel(
            text: snippet,
            labels: categories,
            examples: [],
            ruleFallback: ruleClassifyByKeywords(snippet, candidates: categories)
        )
        guard !category.isEmpty,
              let categoryEntry = subjectEntry.categories.first(where: { $0.name == category }) else {
            return subject
        }

        // Level 3: 세부유형 분류 (선택적 — 못 찾으면 카테고리까지만)
        let leaves = categoryEntry.leaves
        let leaf = await classifyOneLevel(
            text: snippet,
            labels: leaves,
            examples: [],
            ruleFallback: ruleClassifyByKeywords(snippet, candidates: leaves)
        )
        if leaf.isEmpty {
            return "\(subject) > \(category)"
        }
        return "\(subject) > \(category) > \(leaf)"
    }

    /// 한 단계 라벨 분류 — LLM 호출 후 라벨 매칭, 실패 시 룰베이스 폴백.
    private func classifyOneLevel(
        text: String,
        labels: [String],
        examples: [(String, String)],
        ruleFallback: String
    ) async -> String {
        guard case .ready = state, !labels.isEmpty else { return ruleFallback }
        var promptLines: [String] = [
            "다음 한국 법률 텍스트를 정확히 아래 라벨 중 하나로 분류하라. 라벨 외 다른 출력 금지.",
            "라벨: \(labels.joined(separator: ", "))"
        ]
        if !examples.isEmpty {
            promptLines.append("")
            promptLines.append("예시:")
            for (input, output) in examples {
                promptLines.append("입력: \"\(input)\" → \(output)")
            }
        }
        promptLines.append("")
        promptLines.append("입력: \"\(text)\"")
        promptLines.append("라벨:")
        let prompt = promptLines.joined(separator: "\n")

        // 3초 타임아웃
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else { return "" }
                do {
                    let raw = try await self.generateUsingBestAvailableEngine(
                        prompt: prompt, maxTokens: 12, purpose: "taxonomy_classify"
                    )
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
                    // 라벨 정확 매칭 (포함 검사로 prefix/suffix 잡음 허용)
                    for label in labels where firstLine.contains(label) {
                        return label
                    }
                    return ""
                } catch {
                    return ""
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return ""
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
        return result.isEmpty ? ruleFallback : result
    }

    /// 과목 라벨을 키워드로 추정하는 룰베이스 폴백.
    private func ruleClassifySubject(_ text: String) -> String {
        let lower = text
        let signals: [(label: String, hints: [String])] = [
            ("형사소송법", ["수사", "압수", "수색", "영장", "체포", "구속", "증거", "전문진술", "위법수집", "공판", "검사"]),
            ("헌법", ["헌법", "기본권", "위헌", "합헌", "한정위헌", "헌법불합치", "과잉금지", "표현의자유", "평등권"]),
            ("경찰학", ["경찰관", "경찰관직무집행법", "불심검문", "보호조치", "직무집행", "경찰위원회", "자치경찰"]),
            ("형법", ["살인", "절도", "강도", "사기", "횡령", "배임", "상해", "폭행", "성범죄", "정당방위", "미수", "공동정범", "고의", "과실", "위증", "모해위증", "공범", "공동피고인", "위증죄", "증인적격"])
        ]
        for entry in signals where entry.hints.contains(where: { lower.contains($0) }) {
            return entry.label
        }
        return ""
    }

    /// 후보 라벨 중 텍스트에 가장 많이 포함된 라벨을 반환 (단순 키워드 매칭).
    private func ruleClassifyByKeywords(_ text: String, candidates: [String]) -> String {
        var best = ""
        var bestScore = 0
        for label in candidates {
            // 라벨 자체 매칭 + 첫 두 글자 매칭(예: "정당방위"→"정당", "압수·수색"→"압수")
            let score = (text.contains(label) ? 2 : 0)
                + (label.count >= 2 && text.contains(String(label.prefix(2))) ? 1 : 0)
            if score > bestScore {
                bestScore = score
                best = label
            }
        }
        return bestScore >= 1 ? best : ""
    }

    /// 룰베이스 합성에 LLM 분류 결과를 우선 사용하는 비동기 버전.
    /// LLM이 5초 내 라벨을 반환하지 못하면 룰베이스 결과를 사용한다.
    private func composeStudyCardOneLineAsync(caseItem: APICase, issueShort: String, holdingShort: String) async -> String {
        // 룰베이스 verdict가 비어있을 때만 LLM 호출 (이미 명확하면 비용 절약)
        let ruleVerdict = extractVerdictPhrase(holdingShort)
        var verdict = ruleVerdict
        if verdict.isEmpty && !holdingShort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 5초 타임아웃
            verdict = await withTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return "" }
                    return await self.classifyVerdictWithLLM(holding: holdingShort)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return ""
                }
                let first = await group.next() ?? ""
                group.cancelAll()
                return first
            }
        }

        // composeStudyCardOneLine과 동일 로직, verdict만 외부에서 주입
        let domainLabel: String = {
            let subject = caseItem.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if subject.contains("·") {
                let head = subject.components(separatedBy: "·").first ?? ""
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.count <= 4 { return h }
            }
            if subject.count > 0 && subject.count <= 5 { return subject }
            return ""
        }()
        var name = caseItem.caseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("OCR-") || name.isEmpty { name = caseItem.caseNumber }
        if name.count > 40 { name = String(name.prefix(40)) }
        let issueCore = extractIssueCore(issueShort)
        var parts: [String] = []
        if !domainLabel.isEmpty { parts.append("[\(domainLabel)]") }
        if !name.isEmpty { parts.append("\(name) 사건.") }
        if !issueCore.isEmpty {
            if !verdict.isEmpty {
                parts.append("\(issueCore)에 관해 \(verdict) 판단한 사례.")
            } else {
                parts.append("\(issueCore)\(koreanObjectMarker(issueCore)) 다툰 판례.")
            }
        } else if !verdict.isEmpty {
            parts.append("\(verdict) 판단한 사례.")
        } else {
            parts.append("핵심 쟁점이 정리된 판례이다.")
        }
        return smartTruncateKorean(parts.joined(separator: " "), limit: oneLineLimit)
    }

    /// 1B 모델로 OX 변형 문장 한 개 생성 — 원문 한 줄을 자연스러운 부정형으로 바꾼다.
    /// 실패/형식 깨짐 시 빈 문자열 반환 → 호출부 룰베이스 negateStatement로 폴백.
    func generateOXVariantWithLLM(originalSentence: String) async -> String {
        guard case .ready = state else { return "" }
        let body = originalSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 12 && body.count <= 180 else { return "" }
        let prompt = """
        아래 한국 판례 진술을 의미가 정반대가 되도록 한 문장으로 바꿔라. 사실/조문/숫자는 유지하고, 결론 동사만 부정 또는 반대로 바꿔라.
        예) 입력: 영장 없는 압수는 위법하다.
            출력: 영장 없는 압수는 위법하지 않다.
        예) 입력: 손해는 담보 범위에 포함되지 않는다.
            출력: 손해는 담보 범위에 포함된다.
        입력: \(body)
        출력(한 문장만):
        """
        do {
            let raw = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 80, purpose: "ox_variant")
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && !$0.hasPrefix("입력") && !$0.hasPrefix("출력") }) ?? ""
            // 한국어 + 종결어미 + 길이 검증
            guard firstLine.count >= 10 && firstLine.count <= 200 else { return "" }
            guard hasKoreanTerminal(firstLine) || firstLine.hasSuffix("다") else { return "" }
            // 원문과 동일하면 무효
            if firstLine == body { return "" }
            return firstLine
        } catch {
            return ""
        }
    }

    /// 한국어 받침 유무에 따라 "을/를", "은/는", "이/가" 자동 선택.
    private func koreanObjectMarker(_ text: String) -> String {
        guard let last = text.last else { return "을" }
        let scalar = last.unicodeScalars.first!.value
        // 한글 음절 범위 0xAC00..0xD7A3, (코드 - 0xAC00) % 28 != 0 이면 받침 있음
        if scalar >= 0xAC00 && scalar <= 0xD7A3 {
            return ((scalar - 0xAC00) % 28 == 0) ? "를" : "을"
        }
        return "을"
    }

    /// 한국어 종결어미 직후에서 자르고, 없으면 가장 가까운 어절 경계에서 "다."로 마무리한다.
    private func smartTruncateKorean(_ text: String, limit: Int) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // limit 이내면 그대로 반환 (불필요한 truncate 회피)
        if collapsed.count <= limit { return collapsed }
        let snippet = String(collapsed.prefix(limit))
        let endings = ["다.", "다 ", "요.", "임.", "니다.", "였다.", "한다.", "된다.", "이다."]
        var bestIdx: String.Index? = nil
        for ending in endings {
            if let r = snippet.range(of: ending, options: .backwards) {
                if bestIdx == nil || r.upperBound > bestIdx! {
                    bestIdx = r.upperBound
                }
            }
        }
        if let idx = bestIdx, snippet.distance(from: snippet.startIndex, to: idx) >= max(20, limit / 3) {
            return String(snippet[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 종결어미를 못 찾으면 가장 가까운 어절 경계에서 자르고 "…" 대신 "(이하 생략)"으로 명시
        if let space = snippet.range(of: " ", options: .backwards),
           snippet.distance(from: snippet.startIndex, to: space.lowerBound) >= max(20, limit / 3) {
            return String(snippet[..<space.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) + " (이하 생략)"
        }
        return snippet.trimmingCharacters(in: .whitespacesAndNewlines) + " (이하 생략)"
    }

    private func ensureKoreanTerminal(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return stripped }
        let okEndings = ["다.", "요.", "음.", "임.", "였다.", "한다.", "된다.", "이다.", "?", "!", ".", "…"]
        if okEndings.contains(where: { stripped.hasSuffix($0) }) { return stripped }
        if stripped.hasSuffix("다") || stripped.hasSuffix("요") {
            return stripped + "."
        }
        return stripped + "…"
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

        // 캐시 히트 — 동일 case + count 면 즉시 반환
        let oxKey = "ox:\(caseItem.caseNumber):\(count)"
        if let cached = oxCache[oxKey], !cached.isEmpty {
            return cached
        }

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

        // 퀴즈에 들어갈 본문은 OCR raw가 아닌 digest 결과(issueSummary/holdingSummary)를 우선 사용.
        // 이렇게 해야 "[공YYYY..." 같은 출처 잡음과 두 문장 합쳐진 raw가 노출되지 않는다.
        let digestIssue = (caseItem.issueSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let digestHolding = (caseItem.holdingSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quizBody: String = {
            var parts: [String] = []
            if !digestIssue.isEmpty { parts.append(digestIssue) }
            if !digestHolding.isEmpty { parts.append(digestHolding) }
            if parts.isEmpty {
                return compactSentences.isEmpty ? (caseItem.issueSummary ?? "") : compactSentences
            }
            return parts.joined(separator: " ")
        }()

        let prompt = LLMPromptTemplate.oxQuiz(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            keySentences: quizBody,
            keywords: compactKeywords.isEmpty
                ? [caseItem.subject, caseItem.issueSummary ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                : compactKeywords.prefix(8).joined(separator: ", "),
            count: count,
            decisionHints: buildDecisionHints(text: quizBody, keywords: compactKeywords)
        )

        // v1.0: 서버 분기 제거. 로컬 1B 실패 시 룰 기반 폴백만 사용.
        // 동적 토큰: 문항 수에 비례 (1문항≈70토큰), 상한 360
        let oxMaxTokens = min(360, 100 + 70 * max(1, count))
        do {
            // OX 퀴즈는 IR 추출 결과를 먼저 압축한 뒤 프롬프트에 넣고 생성합니다.
            let rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: oxMaxTokens, purpose: "ox_quiz")
            let parsed = OXQuizQuestion.parseList(rawOutput: rawOutput)
            let filtered = parsed.filter { isUsefulOXItem($0) }
            // 부분 수용: count-1 이상이면 LLM 결과 채택, 부족분은 폴백으로 보강
            if filtered.count >= max(1, count - 1) {
                if filtered.count >= count {
                    let result = Array(filtered.prefix(count))
                    cacheOX(result, forKey: oxKey)
                    return result
                }
                // 부분 결과 + 폴백 보강
                let supplement = buildFallbackOXQuiz(
                    caseItem: caseItem,
                    keySentences: quizBody.isEmpty ? keySentences : quizBody,
                    count: count - filtered.count
                )
                var merged = Array(filtered)
                for item in supplement where !merged.contains(where: { $0.statement == item.statement }) {
                    merged.append(item)
                    if merged.count >= count { break }
                }
                cacheOX(merged, forKey: oxKey)
                return merged
            }
        } catch {}

        // 폴백: digest 기반 quizBody를 우선 사용해 OX 문항을 직접 구성 (raw OCR 노이즈 회피)
        let baseQuiz = buildFallbackOXQuiz(caseItem: caseItem, keySentences: quizBody.isEmpty ? keySentences : quizBody, count: count)
        // 룰베이스로 만든 X 문항(부정형)을 1B 모델 변형 결과로 교체 시도 — 첫 X 문항만 한 개 변형
        let enhanced = await enhanceOXQuizWithLLM(baseQuiz: baseQuiz, caseItem: caseItem)
        cacheOX(enhanced, forKey: oxKey)
        return enhanced
    }

    /// 분류 트리 + 도메인 함정 카탈로그 + 개인화(약점 키워드)를 합쳐
    /// LLM OX 프롬프트에 주입할 체크포인트(최대 3개)를 생성.
    /// 실제 도메인 분류와 함정 셔플은 `LegalAnalyzer` 에 위임한다.
    private func buildDecisionHints(text: String, keywords: [String]) -> [String] {
        let weak = weakKeywordsProvider?() ?? []
        return LegalAnalyzer.buildDecisionHints(
            text: text,
            keywords: keywords,
            userWeakKeywords: weak
        )
    }

    /// 룰베이스 OX 퀴즈 결과의 X 문항(answer == false) 첫 번째를 1B Llama 변형으로 교체.
    /// 5초 내 응답 없거나 형식 깨지면 룰베이스 결과 그대로 반환.
    private func enhanceOXQuizWithLLM(baseQuiz: [OXQuizQuestion], caseItem: APICase) async -> [OXQuizQuestion] {
        guard !baseQuiz.isEmpty else { return baseQuiz }
        // 정답 = O인 첫 문항(원문에 가까운)을 가져와 변형 입력으로 사용
        guard let positiveIdx = baseQuiz.firstIndex(where: { $0.answer == true }),
              let xIdx = baseQuiz.firstIndex(where: { $0.answer == false }) else {
            return baseQuiz
        }
        let source = baseQuiz[positiveIdx].statement

        // taxonomy 경로(">" 기호)나 caseName이 그대로 들어간 메타 문장은 변형 부적합 — 룰베이스 폴백 사용
        if source.contains(" > ") || source.contains("핵심 판례이다") || source.contains("자주 출제") {
            return baseQuiz
        }

        // 5초 타임아웃
        let variant: String = await withTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else { return "" }
                return await self.generateOXVariantWithLLM(originalSentence: source)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return ""
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }

        guard !variant.isEmpty else { return baseQuiz }
        var enhanced = baseQuiz
        enhanced[xIdx] = OXQuizQuestion(
            statement: ensureKoreanTerminal(variant),
            answer: false,
            explanation: "[\(caseItem.caseNumber)] 판례의 결론 방향과 어긋나도록 LLM이 변형한 진술입니다."
        )
        return enhanced
    }

    private func isLowMemoryDevice() -> Bool {
        let memoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return memoryGB <= 6
    }

    private func shouldUseServerForHighDifficulty() -> Bool {
        useFallback || isLowMemoryDevice()
    }

    private func serverGroundedAnswer(question: String, intent: String) async throws -> String {
        let response = try await NetworkService.shared.groundedAnswer(question: question, intent: intent, topK: 4)
        if response.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError.outputParsingFailed
        }
        return response.answer
    }

    private func serverGroundedSummary(caseItem: APICase) async throws -> LLMSummary? {
        let question = "다음 판례를 강의 대체 없이 복습용으로 한 줄로 요약: 사건번호=\(caseItem.caseNumber), 사건명=\(caseItem.caseName), 쟁점=\(caseItem.issueSummary ?? ""), 결론=\(caseItem.holdingSummary ?? "")"
        let answer = try await serverGroundedAnswer(question: question, intent: "summary")

        // 백엔드가 멀티라인을 줄 수도 있으므로 핵심 한 줄만 추려낸다.
        let cleanedOneLine = extractFirstKoreanSentence(from: answer)
        // 학습카드 스타일 한 줄을 우리가 직접 합성한 결과와 비교해, 더 의미있는 쪽을 선택
        // 비동기 버전: 룰베이스 verdict 분류가 비면 1B 모델로 분류 시도 (5초 타임아웃)
        let composedOneLine = await composeStudyCardOneLineAsync(
            caseItem: caseItem,
            issueShort: caseItem.issueSummary ?? "",
            holdingShort: caseItem.holdingSummary ?? ""
        )
        let oneLine: String
        if cleanedOneLine.count >= 20 && hasKoreanTerminal(cleanedOneLine) {
            oneLine = shrink(cleanedOneLine, limit: oneLineLimit)
        } else {
            oneLine = composedOneLine
        }

        // 핵심 쟁점/결론은 OCR 원문 덤프가 들어가지 않도록 짧게 정제한 형태로 사용
        let keyIssue: String = {
            let raw = (caseItem.issueSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return "핵심 쟁점 정보 부족" }
            return ensureKoreanTerminal(shrink(scrubResidualNoise(raw), limit: 130))
        }()
        let ruling: String = {
            let raw = (caseItem.holdingSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return "판결 결론 정보 부족" }
            return ensureKoreanTerminal(shrink(scrubResidualNoise(raw), limit: 130))
        }()
        let exam = ensureKoreanTerminal(shrink(caseItem.examPoints?.isEmpty == false
                          ? caseItem.examPoints!
                          : "시험 포인트 정보 부족", limit: examLimit))

        return LLMSummary(rawOutput: canonicalSummaryRaw(oneLine: oneLine, keyIssue: keyIssue, ruling: ruling, exam: exam))
    }

    /// 멀티라인/리스트형 답변에서 첫 자연 한국어 문장만 골라낸다.
    /// 예: "근거 기반 요약(강의 대체 아님): - 사건: [...] - 쟁점: ..." 형태에서
    /// 의미있는 한 문장만 추출해 oneLineSummary 슬롯에 안전하게 넣는다.
    private func extractFirstKoreanSentence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 1. "[case_number] case_name 사건은 ... 라고 판단한 판례이다." 형태가 들어오면 그대로 사용
        if trimmed.contains("판례이다") || trimmed.contains("판단한 판례") {
            // 줄바꿈 하나 이내, 단일 문장이라면 그대로 반환
            let lines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if lines.count == 1 {
                return lines[0]
            }
        }

        // 2. "- 결론:" 라인이 있으면 결론을 우선 추출 (가장 핵심 한 줄)
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            if line.hasPrefix("- 결론:") || line.hasPrefix("결론:") {
                let v = line.replacingOccurrences(of: #"^[-\s]*결론\s*:\s*"#,
                                                  with: "",
                                                  options: .regularExpression)
                if !v.isEmpty { return v }
            }
        }
        // 3. 첫 번째로 한국어 + 종결어미가 포함된 라인 사용
        for line in lines {
            if line.hasPrefix("-") || line.hasPrefix("[") { continue }
            if hasKoreanTerminal(line) {
                return line
            }
        }
        // 4. 폴백: 비스캐폴딩 첫 라인
        for line in lines {
            if line.hasPrefix("- 사건:") || line.hasPrefix("- 쟁점:") || line.hasPrefix("- 결론:") || line.hasPrefix("- 복습:") {
                continue
            }
            if !line.isEmpty { return line }
        }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private func hasKoreanTerminal(_ text: String) -> Bool {
        let endings = ["다.", "다 ", "요.", "임.", "다고 한다.", "였다.", "이다.", "한다.", "된다."]
        return endings.contains(where: { text.contains($0) }) || text.hasSuffix("다") || text.hasSuffix("요")
    }

    /// 한국어 받침 유무에 따른 조사 자동 선택 (은/는, 이/가, 을/를, 와/과 등)
    /// - Parameters:
    ///   - word: 조사 앞 단어
    ///   - eun: 받침 있을 때 사용할 조사
    ///   - neun: 받침 없을 때 사용할 조사
    private func josa(after word: String, eun: String, neun: String) -> String {
        guard let last = word.unicodeScalars.last else { return neun }
        let v = last.value
        guard v >= 0xAC00 && v <= 0xD7A3 else { return neun }
        let jongseong = (v - 0xAC00) % 28
        return jongseong == 0 ? neun : eun
    }

    private func buildRAGEvidence(caseItem: APICase) async -> String {
        // OCR 임시 케이스는 서버 유사도 검색을 생략
        if caseItem.caseNumber.hasPrefix("OCR-") {
            return ""
        }

        // 세션 캐시 — 같은 case 재진입 시 네트워크 호출 회피
        if let cached = ragCache[caseItem.caseNumber] {
            return cached
        }

        guard let similar = try? await NetworkService.shared.listSimilarCases(caseNumber: caseItem.caseNumber, topK: 3),
              !similar.isEmpty else {
            ragCache[caseItem.caseNumber] = ""
            return ""
        }

        let joined = similar.map {
            let issue = ($0.issueSummary ?? "").prefix(80)
            let holding = ($0.holdingSummary ?? "").prefix(80)
            let exam = ($0.examPoints ?? "").prefix(60)
            return "- \($0.caseNumber) \($0.caseName) [\($0.subject)]: 쟁점=\(issue) / 결론=\(holding) / 포인트=\(exam)"
        }.joined(separator: "\n")
        ragCache[caseItem.caseNumber] = joined
        if ragCache.count > cacheCapacity { ragCache.removeAll() }
        return joined
    }

    /// 캐시 저장 + 단순 capacity 관리 (LRU 아닌 wipe-on-overflow)
    private func cacheSummary(_ summary: LLMSummary, forKey key: String) {
        if summaryCache.count >= cacheCapacity { summaryCache.removeAll() }
        summaryCache[key] = summary
    }
    private func cacheOX(_ items: [OXQuizQuestion], forKey key: String) {
        if oxCache.count >= cacheCapacity { oxCache.removeAll() }
        oxCache[key] = items
    }

    private func buildFallbackOXQuiz(
        caseItem: APICase,
        keySentences: String,
        count: Int
    ) -> [OXQuizQuestion] {
        // OX 후보 문장 추출 — keySentences가 digest issue+holding 합쳐진 형태일 수 있어
        // 마침표/줄바꿈/말줄임 모두 분리자로 사용. 그 후 사건명/잡음 라인은 거부.
        let rawCandidates = keySentences
            .replacingOccurrences(of: "…", with: ".")
            .components(separatedBy: CharacterSet(charactersIn: "。.\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let caseSubjectLower = caseItem.caseName.lowercased()
        let sentences = rawCandidates.filter { s -> Bool in
            guard s.count >= 14 && s.count <= 140 else { return false }
            if s.contains("portal.scourt") || s.contains("http") { return false }
            if s.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" }) { return false }
            // 사건명만으로 이루어진 라인 거부 ("[ 강제추행·..." 같은 헤더)
            if s.lowercased().contains(caseSubjectLower) && s.count <= caseItem.caseName.count + 12 {
                return false
            }
            // 시작이 '[' 인데 닫는 ']' 없는 미닫힘 헤더 라인 거부
            if s.hasPrefix("[") && !s.contains("]") { return false }
            // 인용표기 단독 라인 거부
            if s.range(of: #"^\s*선고\s+\d{2,4}[가-힣]{1,3}\d+\s*판결"#, options: .regularExpression) != nil { return false }
            // 학습카드 placeholder 거부
            if s.contains("OCR에서 추출하지 못했") || s.contains("정보가 부족") || s.contains("정보 부족") {
                return false
            }
            // (신규) 쟁점 제목/사건 라벨 라인 거부 — "...된 사건", "...된 사안", "...문제된 경우" 등은 OX 단정 진술 아님
            if isMetaTopicLine(s) { return false }
            // 종결어미 또는 "여부" 같은 의문 종결이 있어야 OX 변환 가치가 있음
            if !hasKoreanTerminal(s) && !s.contains("여부") && !s.contains("되는지") && !s.contains("해당하는지") {
                return false
            }
            return true
        }

        let fallbackSentences: [String]
        if sentences.isEmpty {
            // 정말 후보가 없으면 caseItem 메타 정보로 안전한 문장 합성
            let issue = (caseItem.issueSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let holding = (caseItem.holdingSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var seeds: [String] = []
            // holding(결론)을 우선 — 보통 단정문이므로 OX 적합도가 높음
            if !holding.isEmpty && !holding.contains("OCR에서 추출하지 못했") && !isMetaTopicLine(holding) {
                seeds.append(holding)
            }
            if !issue.isEmpty && !issue.contains("OCR에서 추출하지 못했") && !isMetaTopicLine(issue) {
                seeds.append(issue)
            }
            if seeds.isEmpty {
                seeds.append("\(caseItem.caseName) 사건은 핵심 쟁점이 정리된 판례이다")
            }
            fallbackSentences = seeds
        } else {
            fallbackSentences = sentences
        }

        let caseNum = caseItem.caseNumber

        // 후보 수 만큼만 생성(메타 placeholder 노출 방지). count 보다 적으면 적은 대로 반환.
        let workingSentences = fallbackSentences
        let actualCount = min(count, max(1, workingSentences.count))

        // O 문항: 원문 그대로 (정답), X 문항: 핵심어를 반대로 표현
        return workingSentences.prefix(actualCount).enumerated().map { idx, sentence in
            let isOAnswer = idx % 2 == 0
            let base = sanitizeQuizStatement(sentence)
            if isOAnswer {
                return OXQuizQuestion(
                    statement: ensureKoreanTerminal(base),
                    answer: true,
                    explanation: "[\(caseNum)] 판결에서 확인된 내용입니다."
                )
            } else {
                let xStatement = negateStatement(base, caseName: caseItem.caseName)
                return OXQuizQuestion(
                    statement: ensureKoreanTerminal(xStatement),
                    answer: false,
                    explanation: "[\(caseNum)] 판결의 취지와 반대되는 진술입니다. 원문을 확인하세요."
                )
            }
        }
    }

    private func isUsefulOXItem(_ item: OXQuizQuestion) -> Bool {
        let statement = item.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard statement.count >= 8 && statement.count <= 96 else { return false }

        let legalRefCount = countMatches(in: statement, pattern: #"제\s*\d+\s*조"#)
        if legalRefCount >= 4 { return false }
        if statement.contains("portal.scourt") || statement.contains("http") { return false }

        // 프롬프트 출력 예시 echo 필터
        let lowered = statement.lowercased()
        let templateEchoes = ["진술 1", "진술 2", "<문항", "<o 또는", "한국어 진술", "statement:"]
        if templateEchoes.contains(where: { lowered.contains($0.lowercased()) }) { return false }

        return true
    }

    private func countMatches(in text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    private func sanitizeQuizStatement(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(제\s*\d+\s*조(?:\s*제\s*\d+\s*항)?(?:\s*제\s*\d+\s*호)?\s*,?\s*){3,}"#, with: "핵심 조문 ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 머리글 잡티 제거: "자 2025마8671 결정", "[권리행사최고및담보취소]", "<...>" 같은 OCR 헤더
        cleaned = cleaned.replacingOccurrences(of: #"^자\s+\d{2,4}[가-힣]{1,3}\d+\s*(결정|판결)?\s*"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"^[<〈][^>〉]*[>〉]\s*"#, with: "", options: .regularExpression)

        // (신규) 꼬리 잡티 제거 — 판례공보 인용 헤더 "[공2026... 1234]", "[공 2026하, 1234]", "(공2026하, 1234)"
        cleaned = cleaned.replacingOccurrences(of: #"\s*\[\s*공\s*\d{4}[^\]]*\]?\s*$"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s*\(\s*공\s*\d{4}[^)]*\)?\s*$"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s*\[제\s*\d{4}-\d+호?\]?\s*$"#, with: "", options: .regularExpression)
        // 끝에 매달린 미닫힘 대괄호 "... [공2026" 잔재 제거
        cleaned = cleaned.replacingOccurrences(of: #"\s*\[[^\]]{0,40}$"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[<〈>〉]", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // (신규) 쟁점 제목 꼬리 "...되는지가 문제된 사건" → "...된다" 진술형 변환
        cleaned = convertTopicLabelToAssertion(cleaned)

        // 조사·접속사로 시작하면 떼어낸다
        let leading = ["는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "의 ", "에 ", "도 ", "와 ", "과 ", "로 ", "으로 "]
        for p in leading where cleaned.hasPrefix(p) {
            cleaned = String(cleaned.dropFirst(p.count))
            break
        }

        return String(cleaned.prefix(88))
    }

    /// 쟁점 제목/사건 라벨 라인인지 판정 — OX 단정 진술로 부적합.
    /// 예: "...되는지가 문제된 사건", "...된 사안", "...에 관한 사건"
    private func isMetaTopicLine(_ s: String) -> Bool {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\[[^\]]*\]?\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\([^)]*\)?\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metaSuffixes = [
            "문제된 사건", "문제 된 사건", "문제된 사안", "문제 된 사안",
            "된 사건", "된 사안", "된 경우",
            "관한 사건", "관련된 사건", "대한 사건",
            "문제된 판례", "된 판례"
        ]
        for suf in metaSuffixes where stripped.hasSuffix(suf) {
            return true
        }
        return false
    }

    /// "...되는지가 문제된 사건" 형태를 "...된다" 단정형으로 변환.
    /// 변환 불가하면 원문 반환(상위에서 isMetaTopicLine로 이미 거른 상태가 정상).
    private func convertTopicLabelToAssertion(_ s: String) -> String {
        // "포함되는지가 문제된 사건" → "포함된다"
        // "인정되는지가 문제된 사건" → "인정된다"
        let patterns: [(String, String)] = [
            (#"되는지가?\s*문제\s*된\s*사건$"#, "된다"),
            (#"되는지가?\s*문제\s*된\s*사안$"#, "된다"),
            (#"할\s*수\s*있는지가?\s*문제\s*된\s*사건$"#, "할 수 있다"),
            (#"해당하는지가?\s*문제\s*된\s*사건$"#, "해당한다"),
            (#"인정되는지가?\s*문제\s*된\s*사건$"#, "인정된다"),
            (#"여부가?\s*문제\s*된\s*사건$"#, "문제가 된다")
        ]
        for (pat, replacement) in patterns {
            if let _ = s.range(of: pat, options: .regularExpression) {
                return s.replacingOccurrences(of: pat, with: replacement, options: .regularExpression)
            }
        }
        return s
    }

    /// 안전한 X 진술 생성 — 단순 단어 치환은 원문이 이미 부정형/긍정형일 때 잘못 라벨될 수 있으므로
    /// 명백한 단방향 패턴만 처리하고 나머지는 "단정 불가" 형태로 전환합니다.
    private func negateStatement(_ statement: String, caseName: String = "") -> String {
        // 명백히 긍정 결론을 단정한 진술만 안전하게 부정으로 뒤집음
        let safeFlips: [(String, String)] = [
            ("해당한다", "해당하지 않는다"),
            ("인정된다", "인정되지 않는다"),
            ("적용된다", "적용되지 않는다"),
            ("성립한다", "성립하지 않는다"),
            ("포함된다", "포함되지 않는다"),
            ("허용된다", "허용되지 않는다"),
            ("위법하다", "적법하다"),
            ("적법하다", "위법하다")
        ]
        for (positive, negative) in safeFlips {
            if statement.contains(positive) && !statement.contains(negative) {
                return String(statement.replacingOccurrences(of: positive, with: negative).prefix(88))
            }
        }
        // 유죄/무죄는 "원심은 무죄로 판단했으나 대법원은 유죄"같은 양방향 등장 가능성이 높아 단순 치환 금지
        // 기본은 "원문 사실과 다르다는 단정"을 덧붙여 안전하게 거짓 진술 생성
        // 사건명이 있으면 "『〇〇 사건』의 결론과 다르다" 형으로 모호성 해소
        let trimmedCaseName = caseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let referent: String = {
            // 메모용 식별자(예: "테스트2", "OCR-2025-...", 사건번호형)이면 "위 판례"로 처리
            if trimmedCaseName.isEmpty { return "위 판례" }
            if trimmedCaseName.hasPrefix("OCR-") { return "위 판례" }
            if trimmedCaseName.range(of: #"^\d{2,4}[가-힣]{1,3}\d+$"#, options: .regularExpression) != nil { return "위 판례" }
            return "『\(trimmedCaseName)』"
        }()
        return String(("\(referent)의 실제 결론은 이와 다르다: " + statement).prefix(88))
    }

    private var activeEngine: LocalLLMEngine {
        // 실제 추론 호출 직전 어느 엔진을 탈지 결정하는 단일 분기점입니다.
        useFallback ? fallbackEngine : primaryEngine
    }
}
