import Foundation

// MARK: - Compat Models (백엔드 시절 사용하던 응답 모델 — 시그니처 호환용)

struct SearchAPIResponse: Decodable {
    let total: Int
    let items: [APICase]
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

// MARK: - Errors

enum NetworkError: LocalizedError {
    case notSupportedOffline
    case caseNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notSupportedOffline:
            return "이 기능은 더 이상 사용되지 않습니다 (온디바이스 모드)"
        case .caseNotFound(let key):
            return "로컬 판례를 찾지 못했습니다: \(key)"
        }
    }
}

// MARK: - NetworkService (로컬 백엔드 프록시)
//
// 2026-05-12 이후 본 앱은 풀 온디바이스 모드로 전환되었습니다.
// 호출 측 수정 폭을 최소화하기 위해 기존 `NetworkService` 메서드 시그니처는 유지하되,
// 내부 구현은 모두 로컬 엔진(`LocalIRPipeline`, `LocalCaseSearchEngine`,
// `LocalSimilarityEngine`)과 `LocalCaseStore` corpus 위에서 동작합니다.
//
// configureBaseURL/healthCheck 등 기존 UI 호환 메서드는 no-op 또는 항상 true 입니다.

actor NetworkService {
    static let shared = NetworkService()
    static let overrideKey = "AISYS_API_BASE_URL_OVERRIDE"
    static let userIDKey = "AISYS_USER_ID"

    private let store: LocalCaseStore

    init(store: LocalCaseStore = .shared) {
        self.store = store
    }

    // MARK: - Compat (UI 잔존 호출 호환)

    func deviceConnectionHint() -> String? { nil }

    func configureBaseURL(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.overrideKey)
    }

    static func currentUserID() -> String {
        if let existing = UserDefaults.standard.string(forKey: userIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: userIDKey)
        return generated
    }

    /// 온디바이스 모드에서는 항상 "건강함" — 검색·IR이 즉시 동작.
    func healthCheck() async -> Bool { true }

    // MARK: - Cases

    /// 키워드로 로컬 corpus 검색 → 점수 정렬된 [APICase].
    /// 검색은 raw 가 포함된 corpus 위에서 수행하지만, 사용자에게 노출될 때는
    /// raw 가 빠진 displayCorpus 의 동일 id 케이스로 치환한다.
    func searchCases(query: String, limit: Int = 10) async throws -> [APICase] {
        let snapshot = store.snapshot()
        let hits = LocalCaseSearchEngine.search(query: query, in: snapshot.searchable, limit: limit)
        return snapshot.displayCases(for: hits)
    }

    /// 최신순 corpus 미리보기 (스캔 케이스가 앞쪽에 위치)
    func listCases(limit: Int = 20) async throws -> [APICase] {
        Array(store.displayCorpus.prefix(limit))
    }

    func getCase(caseNumber: String) async throws -> APICase {
        guard let found = store.find(caseNumber: caseNumber) else {
            throw NetworkError.caseNotFound(caseNumber)
        }
        return found
    }

    /// 유사 판례 — 법률 키워드 확장 + 텍스트 매칭.
    func listSimilarCases(caseNumber: String, topK: Int = 5) async throws -> [APICase] {
        let snapshot = store.snapshot()
        guard let target = snapshot.searchable.first(where: { $0.caseNumber == caseNumber || $0.id == caseNumber }) else {
            throw NetworkError.caseNotFound(caseNumber)
        }
        return snapshot.similar(to: target, topK: topK)
    }

    /// 아직 저장되지 않은 OCR 결과도 사건번호 등록 없이 본문으로 검색한다.
    func listSimilarCases(caseItem: APICase, topK: Int = 5) async throws -> [APICase] {
        store.snapshot().similar(to: caseItem, topK: topK)
    }

    // MARK: - IR Extract

    /// 백엔드 /ir/extract 의 로컬 대체 — `LocalIRPipeline` 호출 (수 ms 소요)
    func irExtract(text: String, topKeywords: Int = 10, topSentences: Int = 5) async throws -> APIIRExtractResponse {
        LocalIRPipeline.extract(text: text, topKeywords: topKeywords, topSentences: topSentences)
    }

    // MARK: - Disabled Endpoints

    func groundedAnswer(question: String, intent: String, topK: Int = 4) async throws -> GroundedAnswerAPIResponse {
        throw NetworkError.notSupportedOffline
    }

    func serverGenerateOXQuiz(
        caseNumber: String,
        caseName: String,
        keySentences: String,
        keywords: [String],
        quizCount: Int = 3
    ) async throws -> [OXQuizQuestion] {
        throw NetworkError.notSupportedOffline
    }
}
