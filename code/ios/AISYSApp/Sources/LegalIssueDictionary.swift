import Foundation

/// 법률 논점 단위. 키워드 1개 + 관련 키워드 + 카테고리 + 중요도.
struct LegalIssue {
    let keyword: String
    let category: String        // 형법 / 형사소송법 / 헌법 / 경찰학 / 일반
    let related: [String]
    let importance: Int         // 1-5, 높을수록 시험 빈출
}

/// 경찰고시 판례 학습용 법률 논점 사전.
///
/// 단순 문자열 매칭이 아닌 "논점 → 관련 논점" 그래프로 사용한다.
/// OCR 결과에서 발견된 키워드 하나가 자동으로 관련 키워드를 끌어와 학습 카드에 노출된다.
enum LegalIssueDictionary {
    static let issues: [LegalIssue] = [
        // ── 형사소송법 · 수사 ────────────────────────────────────────
        .init(keyword: "긴급체포", category: "형사소송법", related: ["압수수색", "사후영장", "증거능력", "체포", "현행범"], importance: 5),
        .init(keyword: "체포", category: "형사소송법", related: ["긴급체포", "현행범", "구속", "영장"], importance: 4),
        .init(keyword: "구속", category: "형사소송법", related: ["영장", "체포", "구속기간"], importance: 4),
        .init(keyword: "현행범", category: "형사소송법", related: ["체포", "긴급체포"], importance: 3),
        .init(keyword: "영장", category: "형사소송법", related: ["압수수색", "체포", "사후영장"], importance: 5),
        .init(keyword: "사후영장", category: "형사소송법", related: ["긴급체포", "압수수색", "증거능력"], importance: 5),
        .init(keyword: "압수수색", category: "형사소송법", related: ["영장", "사후영장", "증거능력", "위법수집증거"], importance: 5),
        .init(keyword: "재수사", category: "형사소송법", related: ["수사준칙", "사법경찰관"], importance: 3),
        .init(keyword: "수사준칙", category: "형사소송법", related: ["사법경찰관", "검사"], importance: 3),

        // ── 형사소송법 · 증거 ────────────────────────────────────────
        .init(keyword: "증거능력", category: "형사소송법", related: ["위법수집증거", "전문법칙", "자백", "임의성"], importance: 5),
        .init(keyword: "위법수집증거", category: "형사소송법", related: ["증거능력", "사후영장", "압수수색"], importance: 5),
        .init(keyword: "전문법칙", category: "형사소송법", related: ["증거능력", "전문진술"], importance: 4),
        .init(keyword: "전문진술", category: "형사소송법", related: ["전문법칙"], importance: 3),
        .init(keyword: "자백", category: "형사소송법", related: ["보강증거", "임의성", "증거능력"], importance: 5),
        .init(keyword: "자백보강법칙", category: "형사소송법", related: ["보강증거", "자백"], importance: 5),
        .init(keyword: "보강증거", category: "형사소송법", related: ["자백", "자백보강법칙"], importance: 4),
        .init(keyword: "임의성", category: "형사소송법", related: ["자백", "증거능력"], importance: 4),

        // ── 형법 · 총론 ──────────────────────────────────────────────
        .init(keyword: "구성요건", category: "형법", related: ["고의", "과실", "위법성", "책임"], importance: 5),
        .init(keyword: "위법성", category: "형법", related: ["정당방위", "긴급피난", "정당행위"], importance: 5),
        .init(keyword: "책임", category: "형법", related: ["고의", "과실", "심신장애"], importance: 4),
        .init(keyword: "고의", category: "형법", related: ["과실", "구성요건"], importance: 4),
        .init(keyword: "과실", category: "형법", related: ["고의", "주의의무"], importance: 4),
        .init(keyword: "정당방위", category: "형법", related: ["위법성", "긴급피난", "상당성"], importance: 4),
        .init(keyword: "긴급피난", category: "형법", related: ["위법성", "정당방위"], importance: 3),
        .init(keyword: "미수", category: "형법", related: ["기수", "예비", "실행의 착수"], importance: 4),
        .init(keyword: "기수", category: "형법", related: ["미수"], importance: 3),
        .init(keyword: "공범", category: "형법", related: ["공동정범", "교사", "방조", "정범"], importance: 4),
        .init(keyword: "공동정범", category: "형법", related: ["공범", "정범"], importance: 4),
        .init(keyword: "교사", category: "형법", related: ["공범", "방조"], importance: 3),
        .init(keyword: "방조", category: "형법", related: ["공범", "교사"], importance: 3),

        // ── 형법 · 각론 ──────────────────────────────────────────────
        .init(keyword: "강제추행", category: "형법", related: ["성폭력", "폭행", "협박"], importance: 4),
        .init(keyword: "성폭력", category: "형법", related: ["강제추행", "강간"], importance: 4),
        .init(keyword: "절도", category: "형법", related: ["재산범죄", "점유"], importance: 3),
        .init(keyword: "강도", category: "형법", related: ["재산범죄", "폭행", "협박"], importance: 3),
        .init(keyword: "사기", category: "형법", related: ["재산범죄", "기망"], importance: 3),
        .init(keyword: "횡령", category: "형법", related: ["배임", "재산범죄"], importance: 3),
        .init(keyword: "배임", category: "형법", related: ["횡령", "재산범죄"], importance: 3),

        // ── 헌법 ────────────────────────────────────────────────────
        .init(keyword: "위헌", category: "헌법", related: ["합헌", "헌법재판소", "기본권", "과잉금지"], importance: 5),
        .init(keyword: "합헌", category: "헌법", related: ["위헌", "헌법재판소"], importance: 4),
        .init(keyword: "헌법불합치", category: "헌법", related: ["위헌", "한정위헌"], importance: 4),
        .init(keyword: "한정위헌", category: "헌법", related: ["위헌", "헌법불합치"], importance: 3),
        .init(keyword: "기본권", category: "헌법", related: ["과잉금지", "최소침해", "법익균형"], importance: 5),
        .init(keyword: "과잉금지", category: "헌법", related: ["기본권", "최소침해", "법익균형", "목적의 정당성"], importance: 5),
        .init(keyword: "최소침해", category: "헌법", related: ["과잉금지", "기본권"], importance: 4),
        .init(keyword: "법익균형", category: "헌법", related: ["과잉금지", "기본권"], importance: 4),
        .init(keyword: "평등권", category: "헌법", related: ["기본권", "차별"], importance: 3),

        // ── 경찰학 / 행정 ────────────────────────────────────────────
        .init(keyword: "국가경찰위원회", category: "경찰학", related: ["자치경찰위원회", "위원회"], importance: 4),
        .init(keyword: "자치경찰위원회", category: "경찰학", related: ["국가경찰위원회", "위원회"], importance: 4),
        .init(keyword: "소청심사", category: "경찰학", related: ["징계", "공무원"], importance: 3),
        .init(keyword: "징계", category: "경찰학", related: ["소청심사", "공무원"], importance: 3),
        .init(keyword: "정보공개", category: "경찰학", related: ["행정처분"], importance: 2),
        .init(keyword: "행정처분", category: "경찰학", related: ["취소", "무효", "재량"], importance: 3),
    ]

    /// keyword → LegalIssue 빠른 조회 인덱스
    static let index: [String: LegalIssue] = {
        var m: [String: LegalIssue] = [:]
        for issue in issues { m[issue.keyword] = issue }
        return m
    }()

    /// 본문에서 발견된 직접 키워드 + 그 키워드의 관련 키워드를 모은다.
    /// - 반환: (직접 발견된 키워드, 관련 키워드로 확장된 추가 키워드)
    static func detect(in text: String) -> (direct: [String], related: [String]) {
        var direct: [String] = []
        var seen: Set<String> = []
        for issue in issues where text.contains(issue.keyword) {
            if seen.insert(issue.keyword).inserted {
                direct.append(issue.keyword)
            }
        }
        // 직접 발견된 것의 related 만 확장 (없으면 빈 배열)
        var related: [String] = []
        for d in direct {
            guard let issue = index[d] else { continue }
            for r in issue.related where !seen.contains(r) {
                seen.insert(r)
                related.append(r)
            }
        }
        return (direct, related)
    }

    /// 카테고리(과목) 추론. 가장 많이 매칭된 카테고리 반환. 동률 시 형사소송법 우선.
    static func inferCategory(from foundKeywords: [String]) -> String {
        var counter: [String: Int] = [:]
        for kw in foundKeywords {
            if let issue = index[kw] {
                counter[issue.category, default: 0] += issue.importance
            }
        }
        let priority = ["형사소송법", "형법", "헌법", "경찰학"]
        let best = counter.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return (priority.firstIndex(of: lhs.key) ?? 99) > (priority.firstIndex(of: rhs.key) ?? 99)
        }
        return best?.key ?? "일반"
    }
}
