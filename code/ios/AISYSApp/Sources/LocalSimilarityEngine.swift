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
    func findSimilar(query: String, in candidates: [APICase], topK: Int = 3) -> [APICase] {
        guard let embedding else { return [] }
        let queryVec = vector(for: query, using: embedding)
        guard !queryVec.isEmpty else { return [] }

        let scored: [(APICase, Double)] = candidates.compactMap { item in
            let text = [item.caseName, item.subject, item.issueSummary ?? "", item.holdingSummary ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let v = vector(for: text, using: embedding)
            guard !v.isEmpty else { return nil }
            return (item, cosine(queryVec, v))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .filter { $0.1 > 0.35 } // 너무 무관한 결과 컷
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
}
