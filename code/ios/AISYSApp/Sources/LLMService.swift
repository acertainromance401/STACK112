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
    private let lowMemoryTokenCap = 96
    private let normalTokenCap = 128

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

        // OCR 케이스나 저사양 환경에서는 서버 grounded 요약을 먼저 시도해
        // 로컬 모델의 거친 출력을 완화합니다.
        if caseItem.caseNumber.hasPrefix("OCR-") || shouldUseServerForHighDifficulty() {
            if let grounded = try? await serverGroundedSummary(caseItem: caseItem) {
                return grounded
            }
        }

        let rawOutput: String
        do {
            rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 128, purpose: "summarize")
        } catch {
            if let grounded = try? await serverGroundedSummary(caseItem: caseItem) {
                return grounded
            }
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
        if let grounded = try? await serverGroundedSummary(caseItem: caseItem) {
            return grounded
        }
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

        // 고난도(비교)는 저사양 또는 로컬 엔진 상태가 불안정하면 서버 근거 기반 응답을 우선 시도
        if shouldUseServerForHighDifficulty() {
            if let serverAnswer = try? await serverGroundedAnswer(question: question, intent: "compare") {
                return serverAnswer
            }
        }

        do {
            return try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 220, purpose: "compare")
        } catch {
            if let serverAnswer = try? await serverGroundedAnswer(question: question, intent: "compare") {
                return serverAnswer
            }
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
            .filter { !$0.isEmpty }

        // Always use caseItem fields for structured content — LLM output used only for oneLine hint
        let keyIssue = caseItem.issueSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruling = caseItem.holdingSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exam = caseItem.examPoints?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !semanticLines.isEmpty || keyIssue != nil else {
            return buildSummaryOutput(caseItem: caseItem)
        }

        let oneLine = semanticLines.first ?? caseItem.caseName

        return """
        - one_line_summary: \(oneLine)
        - key_issue: \((keyIssue?.isEmpty == false) ? keyIssue! : "핵심 쟁점 정보가 부족합니다")
        - ruling_point: \((ruling?.isEmpty == false) ? ruling! : "판결 결론 정보가 부족합니다")
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
        // 줄바꿈 제거 + 종결어미 보정으로 카드에 어색하게 잘리지 않게 한다.
        func sanitize(_ s: String, limit: Int) -> String {
            let cleaned = s.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return smartTruncateKorean(cleaned, limit: limit)
        }
        let name = sanitize(caseItem.caseName, limit: 80)
        let nameTopic = josa(after: name, eun: "은", neun: "는")
        let issue = sanitize(caseItem.issueSummary ?? "주요 쟁점 정보가 부족하다.", limit: keyIssueLimit)
        let holding = sanitize(caseItem.holdingSummary ?? "판결 결론 정보가 부족하다.", limit: rulingLimit)
        let examPoint = sanitize(caseItem.examPoints ?? "시험 포인트 정보가 부족하다.", limit: examLimit)

        let oneLine: String = {
            let trimmedIssue = String(issue.prefix(70)).trimmingCharacters(in: .whitespaces)
            if trimmedIssue.isEmpty {
                return "\(name)\(nameTopic) 핵심 쟁점이 정리된 판례이다."
            }
            return "\(name)\(nameTopic) \(trimmedIssue) 쟁점을 다룬 판례이다."
        }()

        return """
        - one_line_summary: \(oneLine)
        - key_issue: \(ensureKoreanTerminal(issue))
        - ruling_point: \(ensureKoreanTerminal(holding))
        - exam_takeaway: \(ensureKoreanTerminal(examPoint))
        """
    }

    /// 한국어 종결어미 직후에서 자르고, 없으면 ‘…’ 표시.
    private func smartTruncateKorean(_ text: String, limit: Int) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
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
        if let space = snippet.range(of: " ", options: .backwards),
           snippet.distance(from: snippet.startIndex, to: space.lowerBound) >= max(20, limit / 3) {
            return String(snippet[..<space.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return snippet.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
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

        // 고난도(퀴즈 생성)는 저사양 기기에서 서버 규칙 기반 생성 폴백을 우선 시도
        if shouldUseServerForHighDifficulty() {
            if let serverQuiz = try? await NetworkService.shared.serverGenerateOXQuiz(
                caseNumber: caseItem.caseNumber,
                caseName: caseItem.caseName,
                keySentences: compactSentences.isEmpty ? (caseItem.issueSummary ?? "") : compactSentences,
                keywords: compactKeywords,
                quizCount: count
            ), !serverQuiz.isEmpty {
                return serverQuiz
            }
        }

        do {
            // OX 퀴즈는 IR 추출 결과를 먼저 압축한 뒤 프롬프트에 넣고 생성합니다.
            let rawOutput = try await generateUsingBestAvailableEngine(prompt: prompt, maxTokens: 260, purpose: "ox_quiz")
            let parsed = OXQuizQuestion.parseList(rawOutput: rawOutput)
            let filtered = parsed.filter { isUsefulOXItem($0) }
            if !filtered.isEmpty {
                return Array(filtered.prefix(max(1, count)))
            }
        } catch {}

        if let serverQuiz = try? await NetworkService.shared.serverGenerateOXQuiz(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            keySentences: compactSentences.isEmpty ? (caseItem.issueSummary ?? "") : compactSentences,
            keywords: compactKeywords,
            quizCount: count
        ), !serverQuiz.isEmpty {
            return serverQuiz
        }

        // 폴백: keySentences의 첫 문장들을 직접 OX 문항으로 구성
        return buildFallbackOXQuiz(caseItem: caseItem, keySentences: keySentences, count: count)
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

        // 백엔드 응답이 멀티라인일 가능성에 대비해 첫 한국어 문장만 추려 한 줄로 만든다.
        let cleanedOneLine = extractFirstKoreanSentence(from: answer)
        let oneLine = cleanedOneLine.isEmpty
            ? buildFallbackOneLine(caseItem: caseItem)
            : shrink(cleanedOneLine, limit: oneLineLimit)
        let keyIssue = shrink(caseItem.issueSummary?.isEmpty == false
                              ? caseItem.issueSummary!
                              : "핵심 쟁점 정보 부족", limit: keyIssueLimit)
        let ruling = shrink(caseItem.holdingSummary?.isEmpty == false
                            ? caseItem.holdingSummary!
                            : "판결 결론 정보 부족", limit: rulingLimit)
        let exam = shrink(caseItem.examPoints?.isEmpty == false
                          ? caseItem.examPoints!
                          : "시험 포인트 정보 부족", limit: examLimit)

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

    private func buildFallbackOneLine(caseItem: APICase) -> String {
        let nameTopic = josa(after: caseItem.caseName, eun: "은", neun: "는")
        let issueShort = (caseItem.issueSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if issueShort.isEmpty {
            return "[\(caseItem.caseNumber)] \(caseItem.caseName)\(nameTopic) 핵심 쟁점이 정리된 판례이다."
        }
        let trimmedIssue = String(issueShort.prefix(70))
        return "[\(caseItem.caseNumber)] \(caseItem.caseName)\(nameTopic) \(trimmedIssue) 쟁점을 다룬 판례이다."
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

        guard let similar = try? await NetworkService.shared.listSimilarCases(caseNumber: caseItem.caseNumber, topK: 3),
              !similar.isEmpty else {
            return ""
        }

        return similar.map {
            let issue = ($0.issueSummary ?? "").prefix(80)
            let holding = ($0.holdingSummary ?? "").prefix(80)
            let exam = ($0.examPoints ?? "").prefix(60)
            return "- \($0.caseNumber) \($0.caseName) [\($0.subject)]: 쟁점=\(issue) / 결론=\(holding) / 포인트=\(exam)"
        }.joined(separator: "\n")
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
            let base = sanitizeQuizStatement(sentence)
            if isOAnswer {
                return OXQuizQuestion(
                    statement: base,
                    answer: true,
                    explanation: "[\(caseNum)] 판결에서 확인된 내용입니다."
                )
            } else {
                // X 문항: 핵심 진술을 부정형으로 변환해 함정형 학습 유도
                let xStatement = negateStatement(base)
                return OXQuizQuestion(
                    statement: xStatement,
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
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(제\s*\d+\s*조(?:\s*제\s*\d+\s*항)?(?:\s*제\s*\d+\s*호)?\s*,?\s*){3,}"#, with: "핵심 조문 ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(cleaned.prefix(88))
    }

    /// 안전한 X 진술 생성 — 단순 단어 치환은 원문이 이미 부정형/긍정형일 때 잘못 라벨될 수 있으므로
    /// 명백한 단방향 패턴만 처리하고 나머지는 "단정 불가" 형태로 전환합니다.
    private func negateStatement(_ statement: String) -> String {
        // 명백히 긍정 결론을 단정한 진술만 안전하게 부정으로 뒤집음
        let safeFlips: [(String, String)] = [
            ("해당한다", "해당하지 않는다"),
            ("인정된다", "인정되지 않는다"),
            ("적용된다", "적용되지 않는다"),
            ("성립한다", "성립하지 않는다"),
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
        // (원문이 참이면 "원문은 거짓이다"는 거짓이므로 X 라벨이 일관됨)
        return String(("위 판례의 결론은 " + statement + "와 정반대이다").prefix(88))
    }

    private var activeEngine: LocalLLMEngine {
        // 실제 추론 호출 직전 어느 엔진을 탈지 결정하는 단일 분기점입니다.
        useFallback ? fallbackEngine : primaryEngine
    }
}
