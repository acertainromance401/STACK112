import Foundation

// MARK: - API Response Models

struct SearchAPIResponse: Decodable {
    let total: Int
    let items: [APICase]
}

struct RecommendedCasesAPIResponse: Decodable {
    let total: Int
    let items: [APIRecommendedCase]
}

struct WrongAnswersAPIResponse: Decodable {
    let total: Int
    let items: [APIWrongAnswerItem]
}

struct SimilarCasesAPIResponse: Decodable {
    let caseNumber: String
    let total: Int
    let items: [SimilarCaseRef]
}

struct SimilarCaseRef: Decodable {
    let caseId: String
    let similarity: Double
    let rank: Int
}

struct GroundedAnswerAPIRequest: Encodable {
    let question: String
    let intent: String
    let topK: Int
}

struct GroundedCitationAPI: Decodable {
    let caseNumber: String
    let caseName: String
    let quotedText: String
    let reason: String
}

struct GroundedAnswerAPIResponse: Decodable {
    let question: String
    let answer: String
    let citations: [GroundedCitationAPI]
    let safetyFlags: [String]
}

struct ServerOXQuizItem: Decodable {
    let statement: String
    let answer: Bool
    let explanation: String
}

struct LLMSummarizeAPIResponse: Decodable {
    let caseNumber: String
    let oneLineSummary: String
    let keyIssue: String
    let rulingPoint: String
    let examTakeaway: String
    let quiz: [ServerOXQuizItem]
    let citations: [String]
}

// MARK: - Network Errors

enum NetworkError: LocalizedError {
    case badStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "서버 오류 (HTTP \(code))"
        case .emptyResponse: return "서버 응답이 비어 있습니다"
        }
    }
}

// MARK: - NetworkService

actor NetworkService {
    static let shared = NetworkService()
    static let overrideKey = "API_BASE_URL_OVERRIDE"
    static let userIDKey = "AISYS_USER_ID"
#if DEBUG
    private static let fallbackBaseURL = "http://172.27.134.228:8000"
#else
    private static let fallbackBaseURL = "https://api.example.com"
#endif

    private var baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        // Info.plist의 API_BASE_URL 키 또는 환경 기본값 사용
        let override = UserDefaults.standard.string(forKey: Self.overrideKey)
        let plistURL = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        let urlString = (override?.isEmpty == false ? override : plistURL) ?? Self.fallbackBaseURL
        self.baseURL = URL(string: urlString) ?? URL(string: Self.fallbackBaseURL)!

        // 실기기에서 네트워크가 불안정할 때 홈 화면이 오래 멈춘 것처럼 보이지 않도록 타임아웃을 짧게 유지합니다.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    func configureBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.overrideKey)
        }

        let plistURL = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        let next = trimmed.isEmpty ? (plistURL ?? Self.fallbackBaseURL) : trimmed
        if let parsed = URL(string: next) {
            baseURL = parsed
        }
    }

    func currentBaseURLString() -> String {
        baseURL.absoluteString
    }

    func deviceConnectionHint() -> String? {
        guard let host = baseURL.host?.lowercased() else { return nil }
#if targetEnvironment(simulator)
        return nil
#else
        if host == "127.0.0.1" || host == "localhost" {
            return "실기기에서는 127.0.0.1/localhost가 아이폰 자신을 가리킵니다. 맥의 LAN IP(예: http://192.168.x.x:8000)로 변경하세요."
        }
        return nil
#endif
    }

    static func currentUserID() -> String {
        if let existing = UserDefaults.standard.string(forKey: userIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: userIDKey)
        return generated
    }

    /// /search?q=...&limit=... → [APICase]
    func searchCases(query: String, limit: Int = 10) async throws -> [APICase] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let (data, response) = try await session.data(from: components.url!)
        try validate(response)
        
        // JSON 디코딩을 백그라운드 스레드에서 실행 (메인 스레드 블로킹 방지)
        return try await Task.detached(priority: .userInitiated) { [weak self] () -> [APICase] in
            guard let self else { throw NetworkError.emptyResponse }
            let response = try self.decoder.decode(SearchAPIResponse.self, from: data)
            return response.items
        }.value
    }

    /// /cases?limit=... → 최신 published 케이스 목록
    func listCases(limit: Int = 20) async throws -> [APICase] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("cases"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let (data, response) = try await session.data(from: components.url!)
        try validate(response)
        
        // JSON 디코딩을 백그라운드 스레드에서 실행 (메인 스레드 블로킹 방지)
        return try await Task.detached(priority: .userInitiated) { [weak self] () -> [APICase] in
            guard let self else { throw NetworkError.emptyResponse }
            let response = try self.decoder.decode(SearchAPIResponse.self, from: data)
            return response.items
        }.value
    }

    /// /health 상태 점검
    func healthCheck() async -> Bool {
        let url = baseURL.appendingPathComponent("health")
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// /dashboard/recommended?limit=... → 추천 복습 카드
    func listRecommendedCases(limit: Int = 7) async throws -> [APIRecommendedCase] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("dashboard/recommended"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let (data, response) = try await session.data(from: components.url!)
        try validate(response)
        return try decoder.decode(RecommendedCasesAPIResponse.self, from: data).items
    }

    /// /dashboard/wrong-answers?user_id=...&limit=... → 최근 오답 노트
    func listWrongAnswers(userID: String, limit: Int = 20) async throws -> [APIWrongAnswerItem] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("dashboard/wrong-answers"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let (data, response) = try await session.data(from: components.url!)
        try validate(response)
        return try decoder.decode(WrongAnswersAPIResponse.self, from: data).items
    }

    /// /cases/{caseNumber} → APICase
    func getCase(caseNumber: String) async throws -> APICase {
        let url = baseURL
            .appendingPathComponent("cases")
            .appendingPathComponent(caseNumber)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try decoder.decode(APICase.self, from: data)
    }

    /// /cases/{caseNumber}/similar?top_k=... → 유사 판례 상세 목록
    func listSimilarCases(caseNumber: String, topK: Int = 5) async throws -> [APICase] {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("cases")
                .appendingPathComponent(caseNumber)
                .appendingPathComponent("similar"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "top_k", value: String(topK))
        ]

        let (data, response) = try await session.data(from: components.url!)
        try validate(response)
        let similar = try decoder.decode(SimilarCasesAPIResponse.self, from: data)

        var resolved: [APICase] = []
        resolved.reserveCapacity(similar.items.count)

        for item in similar.items.sorted(by: { $0.rank < $1.rank }) {
            if let detail = try? await getCase(caseNumber: item.caseId) {
                resolved.append(detail)
            }
        }
        return resolved
    }

    /// POST /ir/extract — OCR 텍스트 → 키워드 + 핵심문장
    func irExtract(text: String, topKeywords: Int = 10, topSentences: Int = 5) async throws -> APIIRExtractResponse {
        let url = baseURL.appendingPathComponent("ir/extract")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["text": text, "top_keywords": topKeywords, "top_sentences": topSentences] as [String: Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decoder.decode(APIIRExtractResponse.self, from: data)
    }

    /// POST /grounded/answer — 고난도 질문(비교/퀴즈) 서버 근거 기반 응답
    func groundedAnswer(question: String, intent: String, topK: Int = 4) async throws -> GroundedAnswerAPIResponse {
        let url = baseURL.appendingPathComponent("grounded/answer")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = GroundedAnswerAPIRequest(question: question, intent: intent, topK: topK)
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decoder.decode(GroundedAnswerAPIResponse.self, from: data)
    }

    /// POST /llm/summarize — 서버 규칙 기반 OX 퀴즈 생성 폴백
    func serverGenerateOXQuiz(
        caseNumber: String,
        caseName: String,
        keySentences: String,
        keywords: [String],
        quizCount: Int = 3
    ) async throws -> [OXQuizQuestion] {
        let url = baseURL.appendingPathComponent("llm/summarize")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "case_number": caseNumber,
            "case_name": caseName,
            "key_sentences": keySentences,
            "keywords": keywords,
            "generate_quiz": true,
            "quiz_count": quizCount
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let parsed = try decoder.decode(LLMSummarizeAPIResponse.self, from: data)
        return parsed.quiz.map {
            OXQuizQuestion(statement: $0.statement, answer: $0.answer, explanation: $0.explanation)
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.badStatus(http.statusCode)
        }
    }
}
