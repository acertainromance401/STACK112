import Foundation
import NaturalLanguage

/// 온디바이스 한국어 임베딩 기반 유사 판례 검색 엔진.
///
/// - Apple `NLEmbedding(language: .korean)` 단어 임베딩 사용 (iOS 14+).
/// - 외부 모델·서버 호출 없음. 로컬 SwiftData/UserDefaults에 저장된 케이스끼리만 비교.
/// - 문장 임베딩은 단어 임베딩 평균(L2-normalized) 으로 근사.
///
/// 사용 흐름:
///   let candidates = LocalSimilarityEngine.shared.findSimilar(query: text, in: cases, topK: 3)
///
/// 스레드 안전: NLEmbedding 은 read-only 이므로 thread-safe.
/// NLTokenizer 는 mutable string 이 있어 thread-safe 하지 않으므로 호출마다 새로 생성한다.
final class LocalSimilarityEngine: @unchecked Sendable {
    static let shared = LocalSimilarityEngine()

    private let embedding: NLEmbedding?

    private init() {
        self.embedding = NLEmbedding.wordEmbedding(for: .korean)
    }

    /// 후보 케이스 중 query 와 가장 유사한 상위 topK 개를 반환.
    /// - 후보가 비어 있거나 임베딩이 비활성이면 빈 배열 반환.
    ///
    /// 가중 재정렬 (F3, v1.0):
    ///   finalScore = 0.65 · cosine(임베딩 평균)
    ///              + 0.25 · jaccard(토큰 ≥ 2자)
    ///              + 0.10 · 법률쟁점 키워드 일치 비율
    ///
    /// 의도: NLEmbedding 한국어 단어사전은 법률 전문 용어(예: "공무집행방해",
    /// "긴급체포") 커버리지가 약하므로 토큰·도메인 사전 신호로 보완.
    func findSimilar(query: String, in candidates: [APICase], topK: Int = 3) -> [APICase] {
        guard let embedding else { return [] }
        let queryVec = vector(for: query, using: embedding)
        let queryTokens = tokenSet(for: query)
        let queryIssues = legalIssueSet(for: query)
        guard !queryVec.isEmpty || !queryTokens.isEmpty else { return [] }

        let scored: [(APICase, Double)] = candidates.compactMap { item in
            let text = [item.caseName, item.subject, item.issueSummary ?? "", item.holdingSummary ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            // 1) cosine
            var cos = 0.0
            if !queryVec.isEmpty {
                let v = vector(for: text, using: embedding)
                if !v.isEmpty { cos = cosine(queryVec, v) }
            }

            // 2) Jaccard on tokens
            let candTokens = tokenSet(for: text)
            let jacc: Double
            if queryTokens.isEmpty || candTokens.isEmpty {
                jacc = 0
            } else {
                let inter = queryTokens.intersection(candTokens).count
                let union = queryTokens.union(candTokens).count
                jacc = union == 0 ? 0 : Double(inter) / Double(union)
            }

            // 3) 법률 쟁점 일치 비율 (query 쟁점 중 몇 % 가 candidate 에 나타나는가)
            let issueScore: Double
            if queryIssues.isEmpty {
                issueScore = 0
            } else {
                let candIssues = legalIssueSet(for: text)
                let hit = queryIssues.intersection(candIssues).count
                issueScore = Double(hit) / Double(queryIssues.count)
            }

            let final = 0.65 * cos + 0.25 * jacc + 0.10 * issueScore
            return (item, final)
        }
        return scored
            .filter { $0.1 > 0.30 } // 너무 무관한 결과 컷
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    // MARK: - Private

    private func vector(for text: String, using embedding: NLEmbedding) -> [Double] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.korean)
        tokenizer.string = cleaned
        var sum: [Double] = Array(repeating: 0, count: embedding.dimension)
        var count = 0
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let token = String(cleaned[range])
            // 길이 1 토큰·숫자만의 토큰은 임베딩 노이즈가 큼
            if token.count < 2 { return true }
            if token.allSatisfy({ $0.isNumber || $0.isPunctuation }) { return true }
            if let v = embedding.vector(for: token) {
                for i in 0..<sum.count { sum[i] += v[i] }
                count += 1
            }
            return true
        }
        guard count > 0 else { return [] }
        let mean = sum.map { $0 / Double(count) }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return mean.map { $0 / norm }
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        // 둘 다 L2-normalized 이므로 내적 == cosine
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// 텍스트에서 길이 ≥ 2 의 알파벳/한글 토큰만 추출해 Set 반환.
    private func tokenSet(for text: String) -> Set<String> {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.korean)
        tokenizer.string = cleaned
        var set: Set<String> = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let token = String(cleaned[range]).lowercased()
            if token.count < 2 { return true }
            if token.allSatisfy({ $0.isNumber || $0.isPunctuation }) { return true }
            set.insert(token)
            return true
        }
        return set
    }

    /// LegalIssueDictionary 가 인식하는 직접 쟁점 키워드 Set.
    private func legalIssueSet(for text: String) -> Set<String> {
        let detected = LegalIssueDictionary.detect(in: text)
        return Set(detected.direct.map { $0.lowercased() })
    }
}
