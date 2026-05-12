import Foundation
import NaturalLanguage

/// 백엔드 ir_pipeline.py 의 핵심을 Swift 로 포팅한 온디바이스 IR 파이프라인.
///
/// 입력: OCR/원문 텍스트
/// 출력: APIIRExtractResponse 와 동일한 형태 (keywords, keySentences, domain, studyFocus)
///
/// 설계 요점:
/// - 형태소 분석은 Apple `NLTagger` (lexicalClass=.noun) 로 명사만 추출 → KoNLPy 대체
/// - 정형 법률 신호(조문/사건번호/날짜/법원명) 정규식으로 우선 수집
/// - LegalIssueDictionary 가산점으로 시험 빈출 키워드를 상위 정렬
/// - 핵심 문장 점수화: TextRank 대신 (a) 키워드 빈도 (b) 법률 사전 가중치 (c) 정형 신호 가중치
///   를 단순 합산. 짧은 OCR 본문(~수 KB)에선 TextRank 대비 손실 미미하면서 1000배 빠름.
enum LocalIRPipeline {

    // MARK: - Public

    /// IR 추출 메인 엔트리. 동기 함수 (수 ms 안에 종료).
    static func extract(text: String, topKeywords: Int = 10, topSentences: Int = 5) -> APIIRExtractResponse {
        let normalized = normalize(text)
        guard !normalized.isEmpty else {
            return APIIRExtractResponse(keywords: [], keySentences: "", domain: "general_legal", studyFocus: [])
        }

        // 1) 판결문 구조 파싱 — 【판시사항】【판결요지】【참조조문】을 인식하면 분석을 그 위에 올린다.
        //    이 경로가 잡히면 이유(理由) 본문의 잡음(헌법 부수언급, 기본권 등) 영향이 사라진다.
        let parsed = JudgmentParser.parse(normalized)
        if parsed.hasStructure {
            return extractFromParsed(parsed: parsed, fallbackText: normalized, topKeywords: topKeywords, topSentences: topSentences)
        }

        // 2) 폴백 — 구조가 없으면 기존 본문 휴리스틱.
        let keywords = extractKeyphrases(from: normalized, topN: topKeywords)
        let sentences = extractKeySentences(from: normalized, topN: topSentences)
        let domain = inferDomain(text: normalized, keywords: keywords)
        let focus = buildStudyFocus(domain: domain, keywords: keywords, keySentences: sentences)

        return APIIRExtractResponse(keywords: keywords, keySentences: sentences, domain: domain, studyFocus: focus)
    }

    /// 구조 인식 판결문 전용 추출 경로 — 분석 대상 텍스트를 판시사항+판결요지[다수의견]로 한정한다.
    private static func extractFromParsed(parsed: ParsedJudgment, fallbackText: String, topKeywords: Int, topSentences: Int) -> APIIRExtractResponse {
        // 분석 대상 = 판시사항 + 판결요지[다수의견|단일]
        var pieces: [String] = parsed.issues
        let majority = parsed.holdings.filter { $0.opinion == .majority || $0.opinion == .unspecified }
        pieces.append(contentsOf: majority.map { $0.text })
        let analysisCorpus = pieces.joined(separator: "\n")

        // 도메인 — 참조조문 법령명이 가장 결정적인 신호
        let domain = inferDomainFromParsed(parsed: parsed, analysisCorpus: analysisCorpus)

        // 키워드 — 분석 대상에서만 추출 (이유 본문 잡음 차단)
        var keywords = extractKeyphrases(from: analysisCorpus.isEmpty ? fallbackText : analysisCorpus, topN: topKeywords)

        // 참조조문 법령명은 상위로 끌어올린다 (시험적 관점에서 가장 중요)
        for act in parsed.statuteActs.reversed() {
            keywords.removeAll { $0 == act }
            keywords.insert(act, at: 0)
        }

        // 도메인과 무관한 다른 도메인 신호 키워드는 제거 — 형법인데 기본권/과잉금지가 남는 현상 방지
        keywords = filterOffDomainKeywords(keywords, domain: domain)
        if keywords.count > topKeywords { keywords = Array(keywords.prefix(topKeywords)) }

        // 핵심 문장 — 판시사항(쟁점)은 평서문으로 변환, 다수의견은 첫 문장만.
        var keySentencesParts: [String] = []
        for (idx, issue) in parsed.issues.enumerated() {
            let polarity = (idx < parsed.polarities.count) ? parsed.polarities[idx] : .unknown
            let decl = JudgmentParser.declarativeStatement(issue: issue, polarity: polarity)
            if !decl.isEmpty { keySentencesParts.append(decl) }
        }
        for h in majority {
            keySentencesParts.append(JudgmentParser.firstSentence(h.text, limit: 200))
        }
        let keySentences = keySentencesParts.prefix(max(topSentences, 4)).joined(separator: "\n")

        // 학습 포인트 — 도메인에 맞춰 만들되, 첫 줄은 판시사항으로 대체해 본문 문장 노출
        let focus = buildStudyFocus(domain: domain, keywords: keywords, keySentences: keySentences)

        return APIIRExtractResponse(keywords: keywords, keySentences: keySentences, domain: domain, studyFocus: focus)
    }

    /// 참조조문(법령명) → 도메인 매핑. 없으면 분석 대상 텍스트로 폴백.
    private static func inferDomainFromParsed(parsed: ParsedJudgment, analysisCorpus: String) -> String {
        for act in parsed.statuteActs {
            switch act {
            case "형법":                                  return "criminal_law"
            case "형사소송법":                            return "criminal_procedure_evidence"
            case "민법", "민사소송법", "상법":           return "civil_law"
            case "행정소송법", "행정심판법", "행정절차법": return "administrative_law"
            case "경찰관 직무집행법", "경찰법":           return "police_committees"
            default: break
            }
            // 특별 형사법 — 모두 형법 영역
            if act.contains("성폭력") || act.contains("특정범죄가중") || act.contains("특정경제범죄")
                || act.contains("정보통신망") || act.contains("아동·청소년") || act.contains("아동청소년")
                || act.contains("청소년성보호") || act.contains("마약류") || act.contains("도로교통")
                || act.contains("교통사고처리") || act.contains("폭력행위 등 처벌") || act.contains("스토킹")
                || act.contains("공직선거법") || act.contains("국가보안법") {
                return "criminal_law"
            }
            // 행정 영역 특별법
            if act.contains("국가공무원법") || act.contains("지방공무원법") || act.contains("개인정보 보호법")
                || act.contains("정보공개") {
                return "administrative_law"
            }
        }
        // 헌법만 단독으로 있을 때만 헌법 도메인
        if parsed.statuteActs == ["헌법"] { return "constitutional_law" }
        // 참조조문이 없으면 분석 대상 텍스트로 inferDomain
        let kws = extractKeyphrases(from: analysisCorpus, topN: 10)
        return inferDomain(text: analysisCorpus, keywords: kws)
    }

    /// 도메인 외 키워드 제거 — 형법 사건의 키워드에 헌법 전용 용어가 남지 않도록.
    private static func filterOffDomainKeywords(_ keywords: [String], domain: String) -> [String] {
        let constitutionalOnly: Set<String> = ["기본권", "과잉금지", "최소침해", "법익균형", "목적의 정당성", "수단적합성", "위헌", "합헌", "한정위헌", "헌법불합치"]
        if domain == "constitutional_law" { return keywords }
        return keywords.filter { !constitutionalOnly.contains($0) }
    }


    // MARK: - Normalize

    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var s = text
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"www\.\S+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"portal\.scourt\.go\.kr\S*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\t\r\u{000B}\u{000C}]", with: " ", options: .regularExpression)

        // OCR 공백 인공물 보정 — 동사어간/한자어 + 공백 + 어미·조사로 끊긴 패턴을 결합.
        // 판례 OCR에서 흔히 발생하는 "담보하 는", "문제 된", "관 한" 등을 정상 토큰으로 복원.
        s = fixOCRSpacing(s)

        s = s.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OCR 결과에서 단일 음절 어미가 공백으로 떨어져 나오는 인공물을 보정한다.
    /// 예) "담보하 는" → "담보하는", "문제 된" → "문제된", "대 한" → "대한"
    private static func fixOCRSpacing(_ text: String) -> String {
        // 0) 알려진 법률 합성어 — paste 시 줄바꿈/양끝맞춤 공백으로 깨진 형태를 복원.
        //    portal.scourt.go.kr 같은 사이트는 단어 중간에서 줄바꿈이 발생해 한 음절이 따로 떨어진다.
        var s = text
        let knownCompounds: [String] = [
            "송금메모", "통신매체", "통신매체이용음란", "전자금융거래",
            "성폭력처벌법", "성폭력범죄", "성적자기결정권", "성적수치심",
            "정보통신망", "도로교통법", "교통사고처리", "스토킹범죄",
            "청소년성보호", "마약류관리", "보호법익", "구성요건",
            "법리오해", "원심판결", "공소사실", "유죄판결", "무죄판결",
            "헌법재판소", "대법원판결", "위법수집증거", "전문법칙",
            "임의제출", "강제수사", "임의수사", "수색영장", "체포영장",
            "공무집행방해", "주거침입", "음주운전", "특정범죄가중처벌",
            "정당방위", "긴급피난", "과잉방위", "공동정범", "간접정범",
        ]
        for compound in knownCompounds {
            let chars = Array(compound)
            guard chars.count >= 3 else { continue }
            // 각 인접 음절 사이에 공백/줄바꿈이 0~2개 들어간 변형까지 매칭.
            let pattern = chars.map { String($0) }.joined(separator: "[ \\t\\n]{0,2}")
            s = s.replacingOccurrences(of: pattern, with: compound, options: .regularExpression)
        }

        // 1) 동사어간 + 공백 + 어미: "하 는/되 는/있 는/없 는/이 는" 등
        let verbStemPattern = #"([하되있없이리기쓰오가받두주]|[하되있없]였|[하되있없]었)\s+(는|던|면|어|아|니|고|자|지|며|여|였|었)"#
        if let regex = try? NSRegularExpression(pattern: verbStemPattern) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2")
        }

        // 2) 자주 끊기는 한자어 + 어미 패턴 (안전한 화이트리스트)
        let pairs: [(String, String)] = [
            ("문제 된", "문제된"),
            ("관 한", "관한"), ("관 하여", "관하여"), ("관 해", "관해"),
            ("대 한", "대한"), ("대 하여", "대하여"), ("대 해", "대해"),
            ("의 한", "의한"), ("의 하여", "의하여"), ("의 해", "의해"),
            ("따 라", "따라"), ("따 른", "따른"), ("따 라서", "따라서"),
            ("위 한", "위한"), ("위 하여", "위하여"),
            ("포함 되", "포함되"), ("배제 되", "배제되"),
            ("인정 되", "인정되"), ("부정 되", "부정되"),
        ]
        for (a, b) in pairs {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    // MARK: - Keyword Extraction

    private static let stopwords: Set<String> = [
        "이","가","은","는","을","를","의","에","에서","로","으로",
        "와","과","도","만","에게","한","하여","하고","하는","있는",
        "그","및","또는","등","위","위한","따라","대한","관한",
        "있다","없다","된다","한다","것","수","바","때","경우",
    ]

    private static let particleSuffixes: [String] = [
        "으로서","으로써","이라고","라고","이라는","라는",
        "에서","으로","에게","에서의","에서는","에서도",
        "이라","이며","이고","이다","이나","이든","이라도",
        "은","는","이","가","을","를","의","에","도","만",
        "와","과","로","께","께서","한테",
        "하였다","되었다","되었으며","하였으며","되었고","하였고",
        "한다","했다","되며","하며","하고","되고",
        "하여","되어","하자","하는","되는","있는","없는",
        "있다","없다","이다","였다",
        "다고","라고","이라고","는지","은지","였는지","였다고",
        "하다고","한다고","된다고","되다고",
        "하는지","되는지","있는지","없는지",
        "이라는","라는","다는","하게","되게",
    ]

    private static let legalTermHints: Set<String> = [
        "위법","적법","고의","과실","구성요건","책임","정당방위",
        "긴급피난","상당","필요","영장","압수","수색","증거",
        "공소","기소","무죄","유죄","양형","재심","항소","상고",
        "체포","구속","자백","진술","피고인","피의자","교사","방조",
        "미수","기수","정범","공범","공동정범","간접정범","처벌","법정형",
        "전문법칙","위법수집증거","임의성","전문진술","임의수사","강제수사",
        "압수수색","사법경찰관","수사준칙","재수사","재체포","재구속",
        "위헌","합헌","기본권","과잉금지","최소침해","법익균형",
        "평등권","표현의자유","신체의자유","행복추구권","직업선택",
        "헌법불합치","한정위헌","헌법재판소",
        "행정처분","행정행위","취소","무효","재량","기속","신뢰보호",
        "법치행정","허가","특허","인가","신고",
        "위원회","국가경찰위원회","자치경찰위원회","정보공개","징계",
        "소청심사","심의위원회",
        "판단","판시","인정","부정","허용","금지","효력","성립",
        "해당","적용","위반",
    ]

    private static let legalSuffixEndings: [String] = ["죄","조","법","권","위","형","심","소","처분","결정","판결"]

    /// 정형 법률 신호 (조문, 사건번호, 날짜, 법원)
    private static func formalLegalSignals(_ text: String) -> [String] {
        let patterns: [String] = [
            #"제\s*\d+\s*조(?:\s*의\s*\d+)?(?:\s*제\s*\d+\s*항)?(?:\s*제\s*\d+\s*호)?"#,
            #"\d{2,4}\s*[가-힣]{1,3}\s*\d+"#,
            #"\d{4}\s*[.년]\s*\d{1,2}\s*[.월]\s*\d{1,2}\s*[.일]?"#,
            #"(?:대법원|헌법재판소|고등법원|지방법원|가정법원|행정법원|특허법원)"#,
        ]
        var out: [String] = []
        var seen: Set<String> = []
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let m = match, let r = Range(m.range, in: text) else { return }
                let raw = String(text[r]).replacingOccurrences(of: " ", with: "")
                if raw.count >= 2 && seen.insert(raw).inserted {
                    out.append(raw)
                }
            }
        }
        return out
    }

    /// 한국어 조사·어미 제거 (긴 어미 우선 매칭)
    private static func stripEndings(_ token: String) -> String {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count < 3 { return cleaned }
        let sorted = particleSuffixes.sorted { $0.count > $1.count }
        for suffix in sorted {
            if cleaned.hasSuffix(suffix) && cleaned.count - suffix.count >= 2 {
                return String(cleaned.dropLast(suffix.count))
            }
        }
        return cleaned
    }

    /// NLTagger 명사 추출 (가능하면), 실패 시 한글 정규식 폴백
    private static func nounsFromText(_ text: String) -> [String] {
        var nouns: [String] = []
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.korean, range: text.startIndex..<text.endIndex)
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: opts) { tag, range in
            if tag == .noun {
                let token = String(text[range])
                if token.count >= 2 && token.count <= 14 { nouns.append(token) }
            }
            return true
        }
        // NLTagger 가 한국어 토큰을 거의 못 잡는 경우(짧은 텍스트) 정규식 보강
        if nouns.count < 5 {
            let regex = try? NSRegularExpression(pattern: #"[가-힣]{2,14}"#)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex?.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let m = match, let r = Range(m.range, in: text) else { return }
                let raw = String(text[r])
                let cleaned = stripEndings(raw)
                if cleaned.count >= 2 && cleaned.count <= 14 {
                    nouns.append(cleaned)
                }
            }
        }
        return nouns
    }

    static func extractKeyphrases(from text: String, topN: Int) -> [String] {
        var ranked: [String] = []
        var seen: Set<String> = []

        func push(_ term: String) {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { return }
            // 한글·영숫자 1자 이상 포함 필요
            let hasUseful = cleaned.contains { ch in
                ch.isLetter || ch.isNumber || (ch >= "가" && ch <= "힣")
            }
            guard hasUseful, cleaned.count >= 2 else { return }
            seen.insert(cleaned)
            ranked.append(cleaned)
        }

        // 1. 정형 법률 신호 — 최대 2개로 제한 (조항만 나열되는 현상 방지). 본문 명사가 우선 노출되도록 한다.
        let formalSignals = formalLegalSignals(text)
        let formalQuota = min(2, max(0, topN / 4))
        for sig in formalSignals.prefix(formalQuota) {
            push(sig)
            if ranked.count >= topN { return ranked }
        }

        // 1.5. 법률 N-gram 사전 매칭 — NLTagger 가 놓치는 복합 법률 용어를
        //      LegalIssueDictionary 키로 우선 채택. 시험 빈출 용어가 항상 상위에 오게 한다.
        let dictionaryHits = LegalIssueDictionary.detect(in: text)
        let dictionaryQuota = min(4, max(0, topN / 3))
        // importance 내림차순으로 우선순위 부여
        let prioritized = dictionaryHits.direct.sorted { a, b in
            (LegalIssueDictionary.index[a]?.importance ?? 0) > (LegalIssueDictionary.index[b]?.importance ?? 0)
        }
        for term in prioritized.prefix(dictionaryQuota) {
            push(term)
            if ranked.count >= topN { return ranked }
        }

        // 2. 명사 추출 + 어미 제거 + 카운트
        let nouns = nounsFromText(text).map { stripEndings($0) }
        var counts: [String: Int] = [:]
        for n in nouns where n.count >= 2 {
            counts[n, default: 0] += 1
        }

        // 3. 점수화
        var scored: [(String, Double)] = []
        for (term, freq) in counts {
            if stopwords.contains(term) { continue }
            var score = Double(freq)
            if legalTermHints.contains(where: { term.contains($0) }) { score += 1.8 }
            if legalSuffixEndings.contains(where: { term.hasSuffix($0) }) { score += 1.0 }
            // LegalIssueDictionary 가산점 — 시험 빈출 강조
            if let issue = LegalIssueDictionary.index[term] {
                score += Double(issue.importance) * 0.6
            }
            // 동사형 잔재 패널티
            if ["하","되","하여","되며","하며"].contains(where: { term.hasSuffix($0) }) { score -= 0.5 }
            scored.append((term, score))
        }
        scored.sort { $0.1 > $1.1 }
        for (term, _) in scored {
            push(term)
            if ranked.count >= topN { break }
        }
        // 4. 그래도 자리가 남으면 정형 신호 잔여분으로 채움
        if ranked.count < topN {
            for sig in formalSignals.dropFirst(formalQuota) {
                push(sig)
                if ranked.count >= topN { break }
            }
        }
        return ranked
    }

    // MARK: - Sentence Scoring

    /// 한국어 문장 분리 — 종결어미 + 마침표/줄바꿈 기준.
    /// OCR 줄바꿈으로 인해 조사("는/은/이/가/을/를/에/도/와/과/로")로 시작하는
    /// 단편이 생기는 경우 직전 문장과 합쳐 의미 단위를 보존한다.
    static func splitSentences(_ text: String) -> [String] {
        let pattern = #"(?<=[다요죠음임])[\.。]\s+(?=[가-힣\[\d])|(?<=[다요죠음임])\s+(?=\[)|(?<=[\.!?])\s+(?=[가-힣\[\d])|\n+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var splits: [String] = []
        var lastEnd = 0
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let m = match else { return }
            let segRange = NSRange(location: lastEnd, length: m.range.location - lastEnd)
            if segRange.length > 0 {
                splits.append(nsString.substring(with: segRange))
            }
            lastEnd = m.range.location + m.range.length
        }
        if lastEnd < nsString.length {
            splits.append(nsString.substring(with: NSRange(location: lastEnd, length: nsString.length - lastEnd)))
        }

        // 조사·접속사로 시작하는 단편(OCR 줄바꿈 노이즈)을 직전 문장과 병합
        let leadingFragments: [String] = [
            "는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "에 ", "에서 ", "에게 ",
            "도 ", "와 ", "과 ", "로 ", "으로 ", "의 ", "및 ", "또는 ",
            "그리고 ", "하지만 ", "다만 ", "또한 ",
        ]
        var merged: [String] = []
        for raw in splits {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            if !merged.isEmpty, leadingFragments.contains(where: { s.hasPrefix($0) }) {
                merged[merged.count - 1] = merged[merged.count - 1] + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged.filter { $0.count >= 12 }
    }

    static func extractKeySentences(from text: String, topN: Int) -> String {
        let sentences = splitSentences(text)
        if sentences.count <= topN {
            return sentences.joined(separator: "\n")
        }

        // 키워드 후보 (상위 20개)로 빈도 기반 점수
        let keywords = extractKeyphrases(from: text, topN: 20)
        let kwSet = Set(keywords)

        // 점수 = (키워드 포함 수) + (법률 힌트 가중치) + (정형 신호 가중치)
        var scored: [(idx: Int, score: Double)] = []
        for (i, s) in sentences.enumerated() {
            var score = 0.0
            for kw in kwSet where s.contains(kw) {
                score += 1.0
                if let issue = LegalIssueDictionary.index[kw] {
                    score += Double(issue.importance) * 0.3
                }
            }
            for hint in legalTermHints where s.contains(hint) {
                score += 0.2
            }
            // 정형 신호 (조문/사건번호) 포함 시 가중
            if !formalLegalSignals(s).isEmpty { score += 0.3 }
            scored.append((i, score))
        }

        // 상위 topN 인덱스를 원문 순서대로 반환
        let topIdx = scored
            .sorted { $0.score > $1.score }
            .prefix(topN)
            .map { $0.idx }
            .sorted()

        return topIdx.map { sentences[$0] }.joined(separator: "\n")
    }

    // MARK: - Domain & Study Focus

    private static let domainHints: [(name: String, hints: Set<String>)] = [
        ("police_committees",                ["위원회","국가경찰위원회","자치경찰위원회","정보공개위원회","징계위원회","소청심사위원회","심의위원회"]),
        ("constitutional_law",               ["헌법","위헌","합헌","과잉금지원칙","목적","수단","최소침해","법익균형","헌법재판소"]),
        ("criminal_procedure_evidence",      ["형사소송법","증거","전문법칙","자백","압수","수색","영장","증거능력","위법수집증거","유류물"]),
        ("criminal_procedure_investigation", ["수사","체포","구속","재수사","사법경찰관","검사","수사준칙","재체포","재구속"]),
        ("criminal_law",                     ["형법","총론","각론","구성요건","위법성","책임","죄형법정주의","죄수","고의","과실"]),
    ]

    static func inferDomain(text: String, keywords: [String]) -> String {
        // 1차: 기존 키워드 카운트 (이전 IR 동작 호환 유지)
        let corpus = (text + " " + keywords.joined(separator: " ")).lowercased()
        var best = "general_legal"
        var bestScore = 0
        for (name, hints) in domainHints {
            let score = hints.reduce(0) { acc, h in acc + (corpus.contains(h.lowercased()) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                best = name
            }
        }
        if bestScore >= 2 { return best }

        // 2차 (보강): 점수 부족 시 LegalAnalyzer 의 가중치 모델 사용
        let analyzed = LegalAnalyzer.classify(text: text, keywords: keywords)
        if analyzed.confidence >= 0.5 {
            switch analyzed.domain {
            case .criminalProcedure:    return "criminal_procedure_evidence"
            case .criminalLaw:          return "criminal_law"
            case .constitutional:       return "constitutional_law"
            case .policeAdministrative: return "police_committees"
            case .general:              return "general_legal"
            }
        }
        return "general_legal"
    }

    static func buildStudyFocus(domain: String, keywords: [String], keySentences: String) -> [String] {
        let topKeywords = keywords.prefix(4).joined(separator: ", ")
        let firstLine = keySentences.split(separator: "\n").first.map(String.init) ?? ""
        let trimmedFirst = String(firstLine.prefix(90))

        switch domain {
        case "constitutional_law":
            return [
                "10초 분기: 제한 기본권 특정 후 과잉금지/평등심사로 판단",
                "위헌/합헌 결론을 먼저 암기하고, 판례 번호와 연결해서 복습",
                trimmedFirst.isEmpty ? "위헌 사유를 목적·수단·최소침해·법익균형 순서로 분류" : "핵심 문장 체크: \(trimmedFirst)",
            ]
        case "criminal_procedure_evidence":
            return [
                "10초 분기: 임의수사/강제처분 구분 후 영장 원칙 확인",
                "증거 문제는 위법수집-전문법칙-자백법칙 순서로 OX 반복",
                topKeywords.isEmpty ? "핵심 키워드 재확인" : "쟁점 키워드: \(topKeywords)",
            ]
        case "criminal_procedure_investigation":
            return [
                "10초 분기: 체포유형(현행범/긴급/영장)부터 먼저 확정",
                "영장 예외는 긴급성·필요성·사후절차로 나눠 점검",
                trimmedFirst.isEmpty ? "핵심 문장 재확인" : "핵심 문장 체크: \(trimmedFirst)",
            ]
        case "criminal_law":
            return [
                "10초 분기: 구성요건-위법성-책임 순서로 쟁점 위치 확인",
                "정당방위/긴급피난, 미수/불능미수처럼 자주 섞이는 쌍을 분리 암기",
                topKeywords.isEmpty ? "핵심 키워드 재확인" : "쟁점 키워드: \(topKeywords)",
            ]
        case "civil_law":
            return [
                "10초 분기: 청구원인-항변-재항변 구조로 쟁점 위치 확인",
                "요건사실과 입증책임 분담을 먼저 정리하고 결론으로 연결",
                topKeywords.isEmpty ? "핵심 키워드 재확인" : "쟁점 키워드: \(topKeywords)",
            ]
        case "administrative_law":
            return [
                "10초 분기: 처분성-원고적격-협의의 소익 순서로 본안 전 점검",
                "재량/기속 구분 후 비례·신뢰보호 위반 여부 확인",
                topKeywords.isEmpty ? "핵심 키워드 재확인" : "쟁점 키워드: \(topKeywords)",
            ]
        case "police_committees":
            return [
                "10초 분기: 경찰조직/작용/징계 중 어디인지 먼저 분류",
                "위원회별 인원 범위·구성 요건·기한 숫자를 OX로 반복",
                topKeywords.isEmpty ? "한 글자/숫자 함정 지문을 중심으로 오답노트 축적" : "핵심 키워드 묶음: \(topKeywords)",
            ]
        default:
            return [
                "10초 분기: 과목(형법/형소법/헌법/경찰학)을 먼저 확정",
                "핵심 쟁점-결론-시험포인트 3단 구조로 요약 후 복습",
                "헷갈리는 판례는 유사판례 2~3개와 비교하여 차이 암기",
                trimmedFirst.isEmpty ? "예외 요건 확인 후 결론 확정" : "핵심 문장 체크: \(trimmedFirst)",
            ]
        }
    }
}
