import Foundation

// MARK: - Backend API Models

/// FastAPI 백엔드 /search 및 /cases/{caseNumber} 응답 모델
struct APICase: Codable, Identifiable {
    let id: String
    let caseNumber: String
    let caseName: String
    let courtName: String
    let subject: String
    let issueSummary: String?
    let holdingSummary: String?
    let examPoints: String?
    let sourceUrl: String?

    /// LLM 요약 결과를 적용해 기존 CaseDetail로 변환
    func toCaseDetail(llmSummary: LLMSummary? = nil) -> CaseDetail {
        CaseDetail(
            title: caseName,
            issue: llmSummary?.keyIssue ?? issueSummary ?? "쟁점 정보 없음",
            conclusion: llmSummary?.rulingPoint ?? holdingSummary ?? "결론 정보 없음",
            examPoint: llmSummary?.examTakeaway ?? examPoints ?? "시험 포인트 없음",
            similarCases: []
        )
    }

    /// 더미 데이터가 들어있을 때 SearchResultItem으로 변환
    func toSearchResultItem(llmSummary: LLMSummary? = nil) -> SearchResultItem {
        SearchResultItem(
            subtitle: "\(courtName) \(caseNumber)",
            title: caseName,
            summary: llmSummary?.oneLineSummary ?? issueSummary ?? "",
            tags: subject.isEmpty ? [] : ["#\(subject)"],
            detail: toCaseDetail(llmSummary: llmSummary)
        )
    }
}

struct APIWrongAnswerItem: Codable {
    let title: String
    let memo: String
    let date: String

    func toWrongAnswerItem() -> WrongAnswerItem {
        WrongAnswerItem(title: title, memo: memo, date: date)
    }
}

/// POST /ir/extract 응답 — 키워드 + 핵심 문장
struct APIIRExtractResponse: Decodable {
    let keywords: [String]
    let keySentences: String
    let domain: String?
    let studyFocus: [String]?
}

// MARK: - LLM Output Model

/// PromptTemplates.summarize 출력을 파싱한 결과
struct LLMSummary: Equatable {
    let oneLineSummary: String
    let keyIssue: String
    let rulingPoint: String
    let examTakeaway: String

    /// LLM raw 텍스트에서 "- key: value" 패턴을 파싱
    init?(rawOutput: String) {
        let lines = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func canonicalKey(_ rawKey: String) -> String? {
            let key = rawKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "one_line_summary", "one-line-summary", "summary",
                 "한줄요약", "한 줄 요약", "요약":
                return "one_line_summary"
            case "key_issue", "key_issues", "issue", "key_issue_points",
                 "핵심쟁점", "핵심 쟁점", "쟁점":
                return "key_issue"
            case "ruling_point", "holding_point", "held", "reason",
                 "결론", "판결결론", "판결 결론":
                return "ruling_point"
            case "exam_takeaway", "exam_points", "exam_takeaway_points",
                 "포인트", "시험포인트", "시험 포인트":
                return "exam_takeaway"
            default:
                return nil
            }
        }

        func looksLikeTemplateEcho(_ value: String) -> Bool {
            let normalized = value.lowercased()
            if normalized.isEmpty { return true }
            // Chained template keys (e.g. "- foo: - bar: - baz:")
            let colonCount = normalized.components(separatedBy: ":").count - 1
            if colonCount >= 3 { return true }
            // Prompt echo patterns
            if normalized.contains("please help") || normalized.contains("## step") {
                return true
            }
            let badTokens = [
                "one_line_summary", "key_issue", "ruling_point", "exam_takeaway",
                "holding_summary", "[output", "outputformat",
                "summary_key", "evidence_key", "rule_applied"
            ]
            let hitCount = badTokens.filter { normalized.contains($0) }.count
            return hitCount >= 1
        }

        var values: [String: String] = [:]
        var currentKey: String?

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                var keyCandidate = String(parts[0])
                keyCandidate = keyCandidate.replacingOccurrences(of: "-", with: "")
                keyCandidate = keyCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if let key = canonicalKey(keyCandidate) {
                    let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        values[key] = value
                    }
                    currentKey = key
                    continue
                }
            }

            if let key = currentKey {
                let appended = (values[key].map { $0 + " " } ?? "") + line
                values[key] = appended.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard
            let one = values["one_line_summary"],
            let issue = values["key_issue"],
            let ruling = values["ruling_point"],
            let exam = values["exam_takeaway"]
        else { return nil }

        guard
            !looksLikeTemplateEcho(one),
            !looksLikeTemplateEcho(issue),
            !looksLikeTemplateEcho(ruling),
            !looksLikeTemplateEcho(exam)
        else { return nil }

        guard
            one.count >= 2,
            issue.count >= 2,
            ruling.count >= 2,
            exam.count >= 2
        else { return nil }

        self.oneLineSummary = one
        self.keyIssue = issue
        self.rulingPoint = ruling
        self.examTakeaway = exam
    }
}

struct WrongAnswerItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let memo: String
    let date: String
}

struct WrongAnswerNote: Equatable {
    let title: String
    let confusionPoint: String
    let memo: String
}

struct WrongQuizRecord: Identifiable, Codable, Equatable {
    let id: String
    let caseNumber: String
    let caseTitle: String
    let question: String
    let userAnswer: String
    let correctAnswer: String
    let explanation: String
    let caseSummary: String
    let solvedAt: String
    /// taxonomy 경로 또는 과목 (약점 분석용). 구버전 과 호환을 위해 optional.
    let subject: String?

    init(
        id: String = UUID().uuidString,
        caseNumber: String,
        caseTitle: String,
        question: String,
        userAnswer: String,
        correctAnswer: String,
        explanation: String,
        caseSummary: String,
        solvedAt: String,
        subject: String? = nil
    ) {
        self.id = id
        self.caseNumber = caseNumber
        self.caseTitle = caseTitle
        self.question = question
        self.userAnswer = userAnswer
        self.correctAnswer = correctAnswer
        self.explanation = explanation
        self.caseSummary = caseSummary
        self.solvedAt = solvedAt
        self.subject = subject
    }
}

struct SearchResultItem: Identifiable, Equatable {
    let id = UUID()
    let subtitle: String
    let title: String
    let summary: String
    let tags: [String]
    let detail: CaseDetail
}

struct CaseDetail: Equatable {
    let title: String
    let issue: String
    let conclusion: String
    let examPoint: String
    let similarCases: [String]
}

// MARK: - OX Quiz Model

/// LLM이 생성하는 O/X 퀴즈 단일 문항
struct OXQuizQuestion: Identifiable, Equatable {
    let id = UUID()
    let statement: String      // 판단할 진술
    let answer: Bool           // true = O (맞음), false = X (틀림)
    let explanation: String    // 해설

    /// LLM raw 텍스트 "- statement: ...\n- answer: O\n- explanation: ..." 파싱
    static func parseList(rawOutput: String) -> [OXQuizQuestion] {
        // 각 문항은 "---" 구분자로 구분
        let blocks = rawOutput.components(separatedBy: "---")
        return blocks.compactMap { block -> OXQuizQuestion? in
            // "- key: value" 형태에서 첫 번째 ":" 이후를 모두 값으로 사용 (statement 안에 ":" 가 들어가도 안전)
            func value(_ key: String) -> String? {
                let lines = block.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prefixes = ["- \(key):", "-\(key):", "\(key):"]
                    for prefix in prefixes {
                        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                            let raw = String(trimmed.dropFirst(prefix.count))
                            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                return nil
            }
            guard
                let stmt = value("statement"),
                let answerStr = value("answer"),
                let explanation = value("explanation"),
                !stmt.isEmpty,
                !answerStr.isEmpty
            else { return nil }
            // "O", "o", "참", "true"는 O로 처리
            let upper = answerStr.uppercased()
            let answer = upper.hasPrefix("O") || upper.hasPrefix("참") || upper.hasPrefix("TRUE")
            return OXQuizQuestion(statement: stmt, answer: answer, explanation: explanation)
        }
    }
}

struct QuizQuestion: Equatable {
    let title: String
    let prompt: String
    let options: [String]
    let correctIndex: Int
    let explanation: String
    let keywords: [String]

    init(
        title: String,
        prompt: String,
        options: [String],
        correctIndex: Int,
        explanation: String,
        keywords: [String]
    ) {
        self.title = title
        self.prompt = prompt
        self.options = options
        self.correctIndex = correctIndex
        self.explanation = explanation
        self.keywords = keywords
    }

    init?(rawOutput: String, title: String, fallbackKeywords: [String] = []) {
        let lines = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func value(for prefix: String) -> String? {
            lines.first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        let parsedOptions = lines.compactMap { line -> String? in
            guard let range = line.range(of: #"^[1-4]\)\s*(.+)$"#, options: .regularExpression) else {
                return nil
            }
            let matched = String(line[range])
            return matched.replacingOccurrences(of: #"^[1-4]\)\s*"#, with: "", options: .regularExpression)
        }

        guard
            let prompt = value(for: "- prompt:"),
            parsedOptions.count == 4,
            let correctIndexString = value(for: "- correct_index:"),
            let correctIndex = Int(correctIndexString),
            (0...3).contains(correctIndex),
            let explanation = value(for: "- explanation:")
        else {
            return nil
        }

        let citationsRaw = value(for: "- citations:") ?? ""
        let citations = citationsRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        self.title = title
        self.prompt = prompt
        self.options = parsedOptions
        self.correctIndex = correctIndex
        self.explanation = explanation
        self.keywords = citations.isEmpty ? fallbackKeywords : citations
    }
}

final class ReviewStore: ObservableObject {
    @Published var wrongAnswers: [WrongAnswerItem] = []

    @Published var wrongQuizRecords: [WrongQuizRecord] = []

    // MARK: - 저장된 판례 (검색/스캔 이력)
    @Published var savedCases: [APICase] = []
    private static let savedCasesKey = "com.aisys.savedCases"
    private static let wrongQuizRecordsKey = "com.aisys.wrongQuizRecords"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.wrongQuizRecordsKey),
           let decoded = try? JSONDecoder().decode([WrongQuizRecord].self, from: data) {
            wrongQuizRecords = decoded
        }

        if let data = UserDefaults.standard.data(forKey: Self.savedCasesKey),
           let decoded = try? JSONDecoder().decode([APICase].self, from: data) {
            let needsMigration = decoded.contains { $0.caseName != $0.caseNumber }
            let normalized = decoded.map { item in
                APICase(
                    id: item.id,
                    caseNumber: item.caseNumber,
                    caseName: item.caseNumber,
                    courtName: item.courtName,
                    subject: item.subject,
                    issueSummary: item.issueSummary,
                    holdingSummary: item.holdingSummary,
                    examPoints: item.examPoints,
                    sourceUrl: item.sourceUrl
                )
            }
            savedCases = normalized
            if needsMigration {
                persistSavedCases()
            }
        }
    }

    func saveCase(_ apiCase: APICase) {
        guard !savedCases.contains(where: { $0.id == apiCase.id }) else { return }
        let normalized = APICase(
            id: apiCase.id,
            caseNumber: apiCase.caseNumber,
            caseName: apiCase.caseNumber,
            courtName: apiCase.courtName,
            subject: apiCase.subject,
            issueSummary: apiCase.issueSummary,
            holdingSummary: apiCase.holdingSummary,
            examPoints: apiCase.examPoints,
            sourceUrl: apiCase.sourceUrl
        )
        savedCases.insert(normalized, at: 0)
        persistSavedCases()
    }

    func removeCase(id: String) {
        savedCases.removeAll { $0.id == id }
        persistSavedCases()
    }

    private func persistSavedCases() {
        if let data = try? JSONEncoder().encode(savedCases) {
            UserDefaults.standard.set(data, forKey: Self.savedCasesKey)
        }
    }

    func saveWrongAnswer(note: WrongAnswerNote) {
        let item = WrongAnswerItem(
            title: note.title,
            memo: "\(note.confusionPoint) | \(note.memo)",
            date: Self.todayString
        )
        wrongAnswers.insert(item, at: 0)
    }

    func saveWrongQuizRecord(
        caseNumber: String,
        caseTitle: String,
        question: String,
        userAnswer: Bool,
        correctAnswer: Bool,
        explanation: String,
        caseSummary: String,
        subject: String? = nil
    ) {
        let item = WrongQuizRecord(
            caseNumber: caseNumber,
            caseTitle: caseTitle,
            question: question,
            userAnswer: userAnswer ? "O" : "X",
            correctAnswer: correctAnswer ? "O" : "X",
            explanation: explanation,
            caseSummary: caseSummary,
            solvedAt: Self.nowString,
            subject: subject
        )
        wrongQuizRecords.insert(item, at: 0)
        if wrongQuizRecords.count > 200 {
            wrongQuizRecords = Array(wrongQuizRecords.prefix(200))
        }
        persistWrongQuizRecords()
    }

    private func persistWrongQuizRecords() {
        if let data = try? JSONEncoder().encode(wrongQuizRecords) {
            UserDefaults.standard.set(data, forKey: Self.wrongQuizRecordsKey)
        }
    }

    /// 오답 기록 전체 초기화 — 설정 화면 "오답노트 비우기" 버튼에서 호출.
    func clearAllWrongRecords() {
        wrongQuizRecords.removeAll()
        wrongAnswers.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.wrongQuizRecordsKey)
    }

    /// 저장된 판례(검색 즐겨찾기) 전체 비우기 — 설정 화면 "저장 판례 비우기" 버튼에서 호출.
    func clearAllSavedCases() {
        savedCases.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.savedCasesKey)
    }

    /// 자주 틀린 taxonomy/과목 상위 N개 — 약점 카드 표시용.
    /// - "형사소송법 > 증거능력 > 위법수집증거배제" 같이 ` > ` 구분일 경우 상위 두 단계까지만 묶음.
    /// - 빈도 ≥ 2 인 항목만 반환하여 우연한 1회 오답은 제외.
    func weakSubjects(topK: Int = 3) -> [(label: String, count: Int)] {
        var counter: [String: Int] = [:]
        for r in wrongQuizRecords {
            guard let raw = r.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let parts = raw.components(separatedBy: " > ")
            let key = parts.prefix(2).joined(separator: " > ")
            counter[key, default: 0] += 1
        }
        return counter
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { (label: $0.key, count: $0.value) }
    }

    private static var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: Date())
    }

    private static var nowString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: Date())
    }
}
