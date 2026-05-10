import Foundation

/// 로컬 ScannedCase / 시드 APICase 위에서 동작하는 단순 텍스트 검색 엔진.
///
/// NLEmbedding 기반 의미 유사도는 `LocalSimilarityEngine` 가 담당하고,
/// 본 엔진은 사용자 입력 검색어에 대한 빠른 키워드/부분문자열 매칭 + 점수 정렬만 수행한다.
///
/// 점수 = 제목·사건명 매칭(가중 3) + 키워드 매칭(가중 2) + 본문 매칭(가중 1)
enum LocalCaseSearchEngine {

    /// 입력 검색어에 대해 corpus 에서 일치도가 높은 케이스를 반환한다.
    /// - Parameters:
    ///   - query: 사용자가 입력한 자연어 검색어
    ///   - corpus: 검색 대상 APICase 배열 (스캔 케이스 + 번들 시드)
    ///   - limit: 최대 반환 수
    static func search(query: String, in corpus: [APICase], limit: Int = 10) -> [APICase] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(corpus.prefix(limit)) }

        // 검색어를 공백 기준 토큰화 + LegalIssueDictionary 관련 키워드 확장
        let baseTokens = q
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var queryTokens = Set(baseTokens.map { $0.lowercased() })
        let detected = LegalIssueDictionary.detect(in: q)
        for kw in detected.direct + detected.related {
            queryTokens.insert(kw.lowercased())
        }
        // 원문 자체도 부분문자열 매칭에 사용
        let qLower = q.lowercased()

        var scored: [(APICase, Double)] = []
        for c in corpus {
            let title = (c.caseName + " " + c.caseNumber + " " + c.subject).lowercased()
            let keywords = c.subject.lowercased()
            let body = [c.issueSummary, c.holdingSummary, c.examPoints]
                .compactMap { $0 }.joined(separator: " ").lowercased()

            var score = 0.0
            // 1) 원문 부분문자열 매칭 (강한 신호)
            if title.contains(qLower) { score += 5 }
            if body.contains(qLower) { score += 2 }

            // 2) 토큰 단위 매칭
            for tok in queryTokens where tok.count >= 2 {
                if title.contains(tok) { score += 3 }
                if keywords.contains(tok) { score += 2 }
                if body.contains(tok) { score += 1 }
            }

            if score > 0 {
                scored.append((c, score))
            }
        }

        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { $0.0 }
    }

    /// 특정 케이스와 유사한 다른 케이스 후보. 토큰 매칭 기반(actor-safe).
    /// 보다 정밀한 의미 유사도가 필요할 때는 `LocalSimilarityEngine` 을 직접 호출하세요.
    static func similar(to target: APICase, in corpus: [APICase], topK: Int = 5) -> [APICase] {
        let pool = corpus.filter { $0.id != target.id }
        let queryText = [target.caseName, target.subject, target.issueSummary ?? "", target.holdingSummary ?? ""]
            .joined(separator: " ")
        return search(query: queryText, in: pool, limit: topK)
    }
}
