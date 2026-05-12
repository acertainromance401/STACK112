import Foundation

/// 한국 판결문의 구조(【판시사항】【판결요지】【참조조문】【참조판례】 등)를 관대하게 파싱.
/// - 전부 옵셔널: 섹션을 못 찾으면 nil/빈 배열을 돌려주고, 다운스트림은 폴백 경로로 동작.
/// - 마커가 깨져도(`[판시사항]`, `< 판시사항 >`, `판시사항:`, 줄 단독 등) 가능한 한 인식.
/// - 온디바이스 전용: 외부 의존성 없음, Foundation 정규식만 사용.
struct ParsedJudgment {
    /// 판시사항 항목 — `[1] [2]` 단위로 분리 (없으면 1개 항목)
    var issues: [String] = []
    /// 판결요지 항목. 같은 `[N]` 번호 안에서 의견 유형이 갈리면 별도 청크.
    var holdings: [Holding] = []
    /// 참조조문 — "형법 제30조, 제152조" 같은 원문 한 줄
    var statutesRaw: String? = nil
    /// 참조조문에서 추출한 법령 이름 (중복 제거, 등장순)
    var statuteActs: [String] = []
    /// 참조판례 — 사건번호 문자열들 ("2008도3300", "2010도10028" 등)
    var precedents: [String] = []
    /// `(적극)` / `(소극)` 추출 (각 판시사항 항목 인덱스에 맞춰 동일 길이)
    var polarities: [Polarity] = []

    struct Holding {
        var issueNo: Int?     // 1, 2, ... (없으면 nil)
        var opinion: Opinion  // 다수의견/반대의견/보충의견/별개의견/단일
        var text: String
    }

    enum Opinion: String {
        case majority    = "다수의견"
        case dissent     = "반대의견"
        case concurring  = "보충의견"
        case separate    = "별개의견"
        case unspecified = "단일"
    }

    enum Polarity {
        case positive   // (적극)
        case negative   // (소극)
        case limitedPositive // (한정 적극)
        case limitedNegative // (한정 소극)
        case unknown
    }

    /// 섹션을 하나라도 찾았는지 (불완전 입력일 때 빠른 판정용)
    var hasStructure: Bool {
        !issues.isEmpty || !holdings.isEmpty || statutesRaw != nil || !precedents.isEmpty
    }
}

enum JudgmentParser {

    /// 입력 텍스트를 파싱. 어떤 섹션도 못 찾으면 빈 `ParsedJudgment` 반환 (throw 하지 않음).
    static func parse(_ raw: String) -> ParsedJudgment {
        var result = ParsedJudgment()
        guard !raw.isEmpty else { return result }

        // 1) 섹션 분리. 마커는 【…】 [..] <..> "키워드\n" 모두 허용.
        let sections = splitSections(raw)

        // 2) 판시사항 → 항목 분리 + 적극/소극 추출
        if let issuesBody = sections["판시사항"], !issuesBody.isEmpty {
            let items = splitNumberedItems(issuesBody)
            result.issues = items.map { cleanWhitespace($0) }
            result.polarities = items.map { detectPolarity($0) }
        }

        // 3) 판결요지 → 항목별/의견별 분리
        if let holdingBody = sections["판결요지"] ?? sections["결정요지"], !holdingBody.isEmpty {
            result.holdings = parseHoldings(holdingBody)
        }

        // 4) 참조조문 → 원문 + 법령 이름 추출
        if let st = sections["참조조문"], !st.isEmpty {
            let oneLine = cleanWhitespace(st)
            result.statutesRaw = oneLine
            result.statuteActs = extractActNames(from: oneLine)
        }

        // 5) 참조판례 → 사건번호 추출
        if let pp = sections["참조판례"], !pp.isEmpty {
            result.precedents = extractCaseNumbers(from: pp)
        }

        return result
    }

    // MARK: - Section splitting

    private static let sectionKeys: [String] = [
        "판시사항", "판결요지", "결정요지", "참조조문", "참조판례",
        "전 문", "전문", "피 고 인", "피고인", "상 고 인", "상고인",
        "원심판결", "주 문", "주문", "이 유", "이유"
    ]

    /// 가능한 마커들로 본문을 섹션 단위 dict로 분리.
    /// 각 섹션 본문은 다음 마커가 나타나기 전까지의 문자열.
    private static func splitSections(_ text: String) -> [String: String] {
        // 마커 매칭: 【 ... 】 [ ... ] 〔 ... 〕 < ... > 또는 줄 단독 키워드
        // 키워드 내부 공백 허용 ("이 유", "전 문")
        let escapedKeys = sectionKeys.map { $0.replacingOccurrences(of: " ", with: "\\s*") }
        let group = escapedKeys.joined(separator: "|")
        let pattern = #"(?:【\s*("# + group + #")\s*】|\[\s*("# + group + #")\s*\]|〔\s*("# + group + #")\s*〕|<\s*("# + group + #")\s*>|(?:^|\n)\s*("# + group + #")\s*[:：]?\s*(?=\n))"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [:] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [:] }

        var result: [String: String] = [:]
        for (i, m) in matches.enumerated() {
            // 첫 번째로 매칭된 캡처 그룹이 키
            var key = ""
            for g in 1...5 where m.range(at: g).location != NSNotFound {
                key = ns.substring(with: m.range(at: g)).replacingOccurrences(of: " ", with: "")
                if key == "전문" { key = "전 문" }
                if key == "이유" { key = "이 유" }
                break
            }
            if key.isEmpty { continue }
            let start = m.range.location + m.range.length
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            // 같은 키가 여러 번이면 가장 긴 본문을 채택
            if let prev = result[key], prev.count >= body.count { continue }
            result[key] = body
        }
        return result
    }

    // MARK: - Numbered items ([1] [2] ...)

    private static func splitNumberedItems(_ body: String) -> [String] {
        let ns = body as NSString
        let pattern = #"\[\s*(\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [body]
        }
        let matches = regex.matches(in: body, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [body] }
        var items: [String] = []
        for (i, m) in matches.enumerated() {
            let start = m.range.location + m.range.length
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            let cleaned = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { items.append(cleaned) }
        }
        return items.isEmpty ? [body] : items
    }

    // MARK: - Holdings (다수의견 / 반대의견 ...)

    private static func parseHoldings(_ body: String) -> [ParsedJudgment.Holding] {
        let items = splitNumberedItems(body)
        var result: [ParsedJudgment.Holding] = []
        for (idx, item) in items.enumerated() {
            let issueNo = idx + 1
            // 의견 마커 패턴: [다수의견] [대법관 ㅇㅇㅇ의 반대의견] [보충의견] ...
            let ns = item as NSString
            let pattern = #"\[\s*([^\]]*?(?:다수의견|반대의견|보충의견|별개의견))\s*\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                result.append(.init(issueNo: issueNo, opinion: .unspecified, text: cleanWhitespace(item)))
                continue
            }
            let matches = regex.matches(in: item, options: [], range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                result.append(.init(issueNo: issueNo, opinion: .unspecified, text: cleanWhitespace(item)))
                continue
            }
            for (mi, m) in matches.enumerated() {
                let label = ns.substring(with: m.range(at: 1))
                let opinion = classifyOpinion(label)
                let start = m.range.location + m.range.length
                let end = (mi + 1 < matches.count) ? matches[mi + 1].range.location : ns.length
                let chunk = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                let cleaned = cleanWhitespace(chunk)
                if !cleaned.isEmpty {
                    result.append(.init(issueNo: issueNo, opinion: opinion, text: cleaned))
                }
            }
        }
        return result
    }

    private static func classifyOpinion(_ label: String) -> ParsedJudgment.Opinion {
        if label.contains("다수의견") { return .majority }
        if label.contains("반대의견") { return .dissent }
        if label.contains("보충의견") { return .concurring }
        if label.contains("별개의견") { return .separate }
        return .unspecified
    }

    // MARK: - Polarity (적극/소극)

    private static func detectPolarity(_ text: String) -> ParsedJudgment.Polarity {
        if text.contains("(한정 적극)") || text.contains("(한정적극)") { return .limitedPositive }
        if text.contains("(한정 소극)") || text.contains("(한정소극)") { return .limitedNegative }
        if text.contains("(적극)") { return .positive }
        if text.contains("(소극)") { return .negative }
        return .unknown
    }

    // MARK: - 참조조문

    private static let knownActs: [String] = [
        "헌법", "형법", "형사소송법", "민법", "민사소송법", "상법",
        "행정소송법", "행정심판법", "행정절차법",
        "국가공무원법", "지방공무원법", "경찰관 직무집행법", "경찰법",
        "특정범죄가중처벌등에관한법률", "특정경제범죄가중처벌등에관한법률",
        "도로교통법", "정보통신망 이용촉진 및 정보보호 등에 관한 법률",
        "공직선거법", "국가보안법", "변호사법", "새마을금고법"
    ]

    private static func extractActNames(from text: String) -> [String] {
        var acts: [String] = []
        var seen: Set<String> = []
        // 단순 부분 문자열 매칭으로 충분 (긴 이름부터)
        for act in knownActs.sorted(by: { $0.count > $1.count }) {
            if text.contains(act), !seen.contains(act) {
                seen.insert(act); acts.append(act)
            }
        }
        return acts
    }

    // MARK: - 참조판례

    private static func extractCaseNumbers(from text: String) -> [String] {
        let pattern = #"\d{2,4}\s*(?:도|다|두|므|허|초|카|모|러|마|허|헌마|헌가|헌나|헌바|전도)\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var seen: Set<String> = []
        var out: [String] = []
        for m in matches {
            let raw = ns.substring(with: m.range).replacingOccurrences(of: " ", with: "")
            if !seen.contains(raw) { seen.insert(raw); out.append(raw) }
        }
        return out
    }

    // MARK: - utils

    private static func cleanWhitespace(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
