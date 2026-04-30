import Foundation

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

    @Published private(set) var state: LLMState = .idle
    @Published private(set) var loadProgress: Double = 0
    @Published private(set) var activeEngineName: String = "준비 전"

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
        for step in [0.2, 0.45, 0.7] {
            loadProgress = step
            state = .loading(progress: step)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        do {
            try await primaryEngine.loadModel()
            useFallback = false
            activeEngineName = primaryEngine.name
        } catch {
            // llama.cpp 연결 전 단계에서는 폴백 엔진으로 즉시 전환
            try? await fallbackEngine.loadModel()
            useFallback = true
            activeEngineName = fallbackEngine.name
        }

        loadProgress = 1.0
        state = .ready
    }

    // MARK: - Inference

    /// 판례 데이터를 받아 LLM 요약(LLMSummary)을 생성합니다.
    func summarize(caseItem: APICase) async throws -> LLMSummary? {
        guard case .ready = state else { throw LLMError.notReady }

        state = .inferring
        defer {
            if case .inferring = state { state = .ready }
        }

        let prompt = LLMPromptTemplate.summarize(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            issue: caseItem.issueSummary ?? "",
            holding: caseItem.holdingSummary ?? "",
            examPoints: caseItem.examPoints ?? ""
        )

        let rawOutput: String
        do {
            rawOutput = try await activeEngine.generate(prompt: prompt, maxTokens: 256)
        } catch {
            let fallbackRaw = buildSummaryOutput(caseItem: caseItem)
            return LLMSummary(rawOutput: fallbackRaw)
        }
        if let summary = LLMSummary(rawOutput: rawOutput) {
            return summary
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
            let rawOutput = try await activeEngine.generate(prompt: prompt, maxTokens: 320)
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
            return try await activeEngine.generate(prompt: prompt, maxTokens: 320)
        } catch {
            return buildComparisonOutput(question: question, cases: cases)
        }
    }

    // MARK: - Private

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

        let prompt = LLMPromptTemplate.oxQuiz(
            caseNumber: caseItem.caseNumber,
            caseName: caseItem.caseName,
            keySentences: keySentences.isEmpty ? (caseItem.issueSummary ?? "") : keySentences,
            keywords: keywords.isEmpty
                ? [caseItem.subject, caseItem.issueSummary ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                : keywords.prefix(8).joined(separator: ", "),
            count: count
        )

        do {
            let rawOutput = try await activeEngine.generate(prompt: prompt, maxTokens: 512)
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
        useFallback ? fallbackEngine : primaryEngine
    }
}
