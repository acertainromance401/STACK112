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
        //    같은 [N] 안에 ` / ` 로 구분된 sub-쟁점이 있으면 별도 issue 로 분리.
        if let issuesBody = sections["판시사항"], !issuesBody.isEmpty {
            let items = splitNumberedItems(issuesBody)
            var allIssues: [String] = []
            var allPolarities: [ParsedJudgment.Polarity] = []
            for raw in items {
                let cleaned = cleanWhitespace(raw)
                let subs = splitSlashClauses(cleaned)
                for s in subs {
                    allIssues.append(s)
                    allPolarities.append(detectPolarity(s))
                }
            }
            result.issues = allIssues
            result.polarities = allPolarities
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
        "공직선거법", "국가보안법", "변호사법", "새마을금고법",
        // 특별 형사법 — portal.scourt.go.kr 본문에 등장하는 띄어쓰기/축약 형태 포함
        "성폭력범죄의 처벌 등에 관한 특례법", "성폭력범죄의처벌등에관한특례법", "성폭력처벌법",
        "아동·청소년의 성보호에 관한 법률", "아동청소년의 성보호에 관한 법률", "청소년성보호법",
        "마약류 관리에 관한 법률", "마약류관리에관한법률",
        "스토킹범죄의 처벌 등에 관한 법률", "교통사고처리 특례법",
        "폭력행위 등 처벌에 관한 법률", "개인정보 보호법"
    ]

    private static func extractActNames(from text: String) -> [String] {
        var acts: [String] = []
        var seen: Set<String> = []
        // 공백 무시 매칭 — paste/OCR로 들어온 "성폭력 처벌 등에 관한 특례 법" 같은 변형도 잡는다.
        // 텍스트와 act 이름 모두에서 공백/탭을 모두 제거한 뒤 비교.
        let stripped = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        for act in knownActs.sorted(by: { $0.count > $1.count }) {
            let actNoWS = act.replacingOccurrences(of: " ", with: "")
            if seen.contains(act) { continue }
            if stripped.contains(actNoWS) {
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

    /// 판시사항 한 항목 안에서 ` / ` 로 구분된 sub-쟁점을 분리.
    /// - 양옆에 공백이 있는 슬래시만 분리 기준 (분수/URL 보호).
    /// - 각 절은 최소 6자 이상이어야 분할.
    private static func splitSlashClauses(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 공백을 양옆에 두는 " / " 패턴
        let parts = trimmed.components(separatedBy: " / ")
        if parts.count < 2 { return [trimmed] }
        var out: [String] = []
        for raw in parts {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count >= 6 { out.append(s) }
        }
        return out.isEmpty ? [trimmed] : out
    }

    // MARK: - 의문형 → 평서형 변환

    /// 판시사항(`...는지 여부(적극)` 형태)을 자연스러운 평서문으로 변환한다.
    /// 변환 실패 시 입력을 그대로(또는 마커만 제거하고) 반환.
    static func declarativeStatement(issue: String, polarity: ParsedJudgment.Polarity) -> String {
        var s = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // 1) 꼬리 (적극)/(소극)/(한정 적극)/(한정 소극) 제거
        s = s.replacingOccurrences(of: #"\s*\(\s*한정\s*적극\s*\)\s*\.?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\(\s*한정\s*소극\s*\)\s*\.?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\(\s*적극\s*\)\s*\.?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\(\s*소극\s*\)\s*\.?\s*$"#, with: "", options: .regularExpression)

        // 2) 꼬리 "여부" 제거
        s = s.replacingOccurrences(of: #"\s*여\s*부\s*\.?\s*$"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        let isNegative = (polarity == .negative || polarity == .limitedNegative)
        let prefix = (polarity == .limitedPositive || polarity == .limitedNegative) ? "일정한 경우 " : ""

        // 머리 정리 — 직전 sub-issue를 가리키는 "위 "는 카드 단독 표시 시 가독성 저하.
        //   "위 통신매체이용음란죄에서…" → "통신매체이용음란죄에서…"
        if s.hasPrefix("위 ") { s = String(s.dropFirst(2)) }
        // "및 " 로 시작하면 앞 절이 잘린 흔적 — 제거.
        if s.hasPrefix("및 ") { s = String(s.dropFirst(2)) }

        // 3) 의문형 종결 어미 치환 — 긴 패턴부터 매칭
        let replacements: [(suffix: String, positive: String, negative: String)] = [
            ("할 수 있는지", "할 수 있다.", "할 수 없다."),
            ("할 수 없는지", "할 수 없다.", "할 수 있다."),
            ("수 있는지",   "수 있다.",   "수 없다."),
            ("해당하는지", "해당한다.",  "해당하지 않는다."),
            ("성립하는지", "성립한다.",  "성립하지 않는다."),
            ("인정되는지", "인정된다.",  "인정되지 않는다."),
            ("적용되는지", "적용된다.",  "적용되지 않는다."),
            ("허용되는지", "허용된다.",  "허용되지 않는다."),
            ("위반되는지", "위반된다.",  "위반되지 않는다."),
            ("필요한지",   "필요하다.",  "필요하지 않다."),
            ("가능한지",   "가능하다.",  "가능하지 않다."),
            ("타당한지",   "타당하다.",  "타당하지 않다."),
            ("정당한지",   "정당하다.",  "정당하지 않다."),
            ("위법한지",   "위법하다.",  "위법하지 않다."),
            ("적법한지",   "적법하다.",  "적법하지 않다."),
            ("되는지",     "된다.",      "되지 않는다."),
            ("하는지",     "한다.",      "하지 않는다."),
            ("있는지",     "있다.",      "없다."),
            ("없는지",     "없다.",      "있다."),
        ]
        for (suffix, pos, neg) in replacements {
            if s.hasSuffix(suffix) {
                let base = String(s.dropLast(suffix.count))
                return prefix + base + (isNegative ? neg : pos)
            }
        }
        // 4) 일반 "...는지" — 동사 어간을 추정하기 어려우면 마침표만 붙여 반환
        if s.hasSuffix("는지") {
            let base = String(s.dropLast(2))
            return prefix + base + (isNegative ? "지 않는다." : "다.")
        }
        // 5) 변환 불가 — 마침표만 정리
        if !s.hasSuffix(".") { s += "." }
        return prefix + s
    }

    /// 판결요지 본문이 너무 길 때 첫 문장 한 개로 압축.
    static func firstSentence(_ text: String, limit: Int = 200) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if t.count <= limit { return t }
        if let r = t.range(of: #"[.](\s|$)"#, options: .regularExpression),
           t.distance(from: t.startIndex, to: r.lowerBound) >= 40 {
            return String(t[..<r.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(t.prefix(limit)) + "…"
    }

    /// 판시사항 [2]가 "...사안에서, ... 한 사례." 패턴이면 "사례" 절만 도출.
    /// 판결요지가 누락된 paste 입력에서도 결론 카드를 명확하게 채우기 위함.
    /// 예) "피고인이 …으로 기소된 사안에서, 피고인이 … 해당하여 같은 법 제13조의 구성요건을 충족한다는 이유로,
    ///       이와 달리 입장을 취한 원심판결에 법리오해의 잘못이 있다고 한 사례."
    ///   → "피고인이 … 해당하여 같은 법 제13조의 구성요건을 충족한다는 이유로, 이와 달리 입장을 취한 원심판결에 법리오해의 잘못이 있다고 한 사례."
    static func extractConclusionFromIssue2(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // "사례"에서 끝나는 패턴이 아니면 결론형 아님
        guard t.hasSuffix("사례") || t.hasSuffix("사례.") else { return nil }
        // 머리의 "사안에서," 이후 부분만 취한다 — "사안에서,"가 없으면 원문 그대로.
        var s = t
        if let r = s.range(of: "사안에서,") {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let r = s.range(of: "사안에서 ") {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !s.hasSuffix(".") { s += "." }
        // 너무 짧으면 취소 (머리만 잘린 경우)
        guard s.count >= 20 else { return nil }
        return s
    }
}
