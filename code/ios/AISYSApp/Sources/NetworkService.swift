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
    private static let fallbackBaseURL = "http://172.27.212.232:8000"

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
        return try decoder.decode(SearchAPIResponse.self, from: data).items
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
        return try decoder.decode(SearchAPIResponse.self, from: data).items
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

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.badStatus(http.statusCode)
        }
    }
}
