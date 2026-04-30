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

struct APIRecommendedCase: Codable {
    let caseNumber: String
    let caseName: String
    let subject: String
    let issue: String
    let accuracy: Int

    func toCaseStudy() -> CaseStudy {
        CaseStudy(
            subject: subject,
            title: caseName,
            issue: issue,
            accuracy: accuracy
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
        func extract(_ key: String) -> String? {
            guard let range = rawOutput.range(
                of: #"- \#(key):\s*(.+)"#,
                options: .regularExpression
            ) else { return nil }
            return String(rawOutput[range])
                .components(separatedBy: ": ")
                .dropFirst()
                .joined(separator: ": ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard
            let one = extract("one_line_summary"),
            let issue = extract("key_issue"),
            let ruling = extract("ruling_point"),
            let exam = extract("exam_takeaway")
        else { return nil }
        self.oneLineSummary = one
        self.keyIssue = issue
        self.rulingPoint = ruling
        self.examTakeaway = exam
    }
}

struct CaseStudy: Identifiable, Equatable {
    let id = UUID()
    let subject: String
    let title: String
    let issue: String
    let accuracy: Int
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
            func value(_ key: String) -> String? {
                guard let range = block.range(
                    of: #"- \#(key):\s*(.+)"#,
                    options: .regularExpression
                ) else { return nil }
                return String(block[range])
                    .components(separatedBy: ": ")
                    .dropFirst()
                    .joined(separator: ": ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard
                let stmt = value("statement"),
                let answerStr = value("answer"),
                let explanation = value("explanation")
            else { return nil }
            let answer = answerStr.uppercased().hasPrefix("O")
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
    @Published var recommendedCases: [CaseStudy] = []

    @Published var wrongAnswers: [WrongAnswerItem] = []

    @Published var searchResults: [SearchResultItem] = []

    @Published private(set) var isRemoteDashboardLoaded = false

    func saveWrongAnswer(note: WrongAnswerNote) {
        let item = WrongAnswerItem(
            title: note.title,
            memo: "\(note.confusionPoint) | \(note.memo)",
            date: Self.todayString
        )
        wrongAnswers.insert(item, at: 0)
    }

    func applyRemoteDashboard(recommended: [APIRecommendedCase], wrong: [APIWrongAnswerItem]) {
        if !recommended.isEmpty {
            recommendedCases = recommended.map { $0.toCaseStudy() }
        }
        if !wrong.isEmpty {
            wrongAnswers = wrong.map { $0.toWrongAnswerItem() }
        }
        isRemoteDashboardLoaded = true
    }

    private static var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: Date())
    }
}
