import Foundation

/// 판례 텍스트의 도메인 분류·함정 카탈로그·개인화 힌트를 한곳에서 제공한다.
///
/// 설계 의도:
/// - `LocalIRPipeline` 의 단순 키워드 일치 기반 도메인 분류를 *점수+신뢰도* 모델로 확장.
/// - `LLMService.buildDecisionHints` 가 사용하는 결정 트리 힌트를 도메인별 함정 카탈로그와 결합.
/// - `ReviewStore` 오답 기록을 받아 *개인화 학습 힌트* 를 생성한다.
enum LegalAnalyzer {

    // MARK: - Domain Classification

    enum Domain: String {
        case criminalLaw           // 형법
        case criminalProcedure     // 형사소송법
        case constitutional        // 헌법
        case policeAdministrative  // 경찰학/행정
        case general

        var label: String {
            switch self {
            case .criminalLaw: return "형법"
            case .criminalProcedure: return "형소법"
            case .constitutional: return "헌법"
            case .policeAdministrative: return "경찰학"
            case .general: return "일반"
            }
        }
    }

    struct DomainResult {
        let domain: Domain
        let confidence: Double // 0.0 ~ 1.0
        let runnerUp: Domain?  // 신뢰도 0.7 미만일 때만 의미 있음
    }

    /// 도메인별 가중치 키워드. 값이 클수록 도메인 신호가 강함.
    private static let domainSignals: [Domain: [(token: String, weight: Double)]] = [
        .criminalProcedure: [
            ("영장", 2.5), ("긴급체포", 3.0), ("현행범", 2.0), ("압수수색", 2.5),
            ("사후영장", 2.5), ("위법수집증거", 3.0), ("전문법칙", 2.5), ("전문진술", 2.0),
            ("자백", 2.0), ("보강증거", 2.0), ("임의성", 2.0), ("증거능력", 2.5),
            ("임의수사", 2.0), ("강제처분", 2.0), ("수사준칙", 2.0), ("재수사", 1.5),
            ("사법경찰관", 1.5), ("형사소송법", 3.0), ("체포", 1.5), ("구속", 1.5),
        ],
        .criminalLaw: [
            ("구성요건", 2.5), ("위법성", 2.5), ("책임", 1.5), ("고의", 2.0),
            ("과실", 2.0), ("정당방위", 2.5), ("긴급피난", 2.5), ("미수", 2.0),
            ("기수", 1.5), ("불능미수", 2.5), ("공동정범", 2.5), ("교사", 1.5),
            ("방조", 1.5), ("정범", 1.5), ("죄형법정주의", 2.5), ("형법", 3.0),
            ("강제추행", 1.5), ("절도", 1.5), ("강도", 1.5), ("사기", 1.5),
        ],
        .constitutional: [
            ("위헌", 3.0), ("합헌", 2.0), ("헌법불합치", 2.5), ("한정위헌", 2.5),
            ("기본권", 2.5), ("과잉금지", 3.0), ("최소침해", 2.5), ("법익균형", 2.5),
            ("평등권", 2.0), ("표현의 자유", 2.0), ("직업선택", 1.5), ("신체의 자유", 1.5),
            ("헌법재판소", 2.5), ("헌법", 3.0), ("목적의 정당성", 2.0),
        ],
        .policeAdministrative: [
            ("국가경찰위원회", 3.0), ("자치경찰위원회", 3.0), ("위원회", 1.0),
            ("소청심사", 2.5), ("징계위원회", 2.5), ("심의위원회", 2.0),
            ("정보공개", 1.5), ("행정처분", 2.0), ("재량", 1.5), ("기속", 1.5),
            ("신뢰보호", 2.0), ("경찰관 직무집행법", 3.0), ("직무집행", 1.5),
        ],
    ]

    /// 텍스트 + 키워드 입력 → 도메인/신뢰도 산출.
    /// 신뢰도 = bestScore / (bestScore + secondScore + 0.1), 0~1 클램프.
    static func classify(text: String, keywords: [String] = []) -> DomainResult {
        // "형사소송법"이 "형법" substring을 먹고, "헌법상"/"헌법재판소"가 "헌법"을 먹는 문제를 차단.
        var corpus = text + " " + keywords.joined(separator: " ")
        let hasCriminalProc = corpus.contains("형사소송법")
        // 제거: 헌법상/헌법적은 헌법 도메인 신호가 아니다.
        corpus = corpus.replacingOccurrences(of: "헌법재판소", with: " @헌재장@ ")
        corpus = corpus.replacingOccurrences(of: "헌법상", with: " ")
        corpus = corpus.replacingOccurrences(of: "헌법적", with: " ")
        corpus = corpus.replacingOccurrences(of: " @헌재장@ ", with: "헌법재판소")

        var scores: [Domain: Double] = [:]
        for (domain, signals) in domainSignals {
            var s = 0.0
            for sig in signals where corpus.contains(sig.token) {
                // "형법"은 형사소송법 코퍼스에서는 경계 이후(형법제|형법상)에서만 수용.
                if sig.token == "형법" && hasCriminalProc {
                    if corpus.range(of: #"형법(제|상|총칙|각칙)"#, options: .regularExpression) != nil {
                        s += sig.weight
                    }
                    continue
                }
                s += sig.weight
            }
            scores[domain] = s
        }

        guard let top = scores.max(by: { $0.value < $1.value }), top.value > 0 else {
            return DomainResult(domain: .general, confidence: 0, runnerUp: nil)
        }
        let second = scores.filter { $0.key != top.key }.max(by: { $0.value < $1.value })

        let bestScore = top.value
        let secondScore = second?.value ?? 0
        let confidence = bestScore / (bestScore + secondScore + 0.1)

        let domain = bestScore < 2.0 ? .general : top.key
        let runnerUp = (confidence < 0.7 && bestScore >= 2.0) ? second?.key : nil
        return DomainResult(domain: domain, confidence: min(1.0, max(0.0, confidence)), runnerUp: runnerUp)
    }

    // MARK: - Trap Catalog (도메인별 함정 카탈로그)

    /// 각 항목은 OX 프롬프트에 그대로 주입되는 한 줄 힌트.
    /// 매 호출마다 셔플하여 동일 판례에서도 다른 함정이 노출되도록 한다.
    private static let trapCatalog: [Domain: [String]] = [
        .criminalProcedure: [
            "임의수사와 강제처분을 헷갈리게 출제 (피처분자의 동의 유무)",
            "영장주의 원칙과 예외(긴급성·현행성·동의)를 뒤바꿔 출제",
            "사후영장 청구 기한·요건 숫자를 바꾸어 함정 출제",
            "위법수집증거-전문법칙-자백법칙 적용 순서를 뒤바꿔 출제",
            "체포 유형(현행범/긴급/일반)별 요건을 한 줄에서 교차 함정",
            "사법경찰관과 검사의 권한 범위를 바꾸어 출제",
        ],
        .criminalLaw: [
            "정당방위와 긴급피난의 공격 주체를 바꿔 출제",
            "미수와 불능미수, 예비와 미수 경계를 흐리게 출제",
            "공동정범과 종범(교사·방조)을 한 줄에서 혼동",
            "구성요건-위법성-책임 순서를 뒤바꿔 출제",
            "고의와 과실, 인식 있는 과실과 미필적 고의를 혼동",
            "죄수론(상상적 경합/실체적 경합)의 처리 기준을 뒤바꿔 출제",
        ],
        .constitutional: [
            "과잉금지원칙 4단계(목적·수단·최소침해·법익균형) 순서 뒤바꾸기",
            "위헌/합헌 결론을 바꿔 출제",
            "헌법불합치와 한정위헌의 효력을 혼동",
            "평등심사 단계(자의금지/엄격심사)를 바꿔 출제",
            "기본권 주체(자연인/법인/외국인) 인정 여부를 바꿔 출제",
        ],
        .policeAdministrative: [
            "위원회 구성 인원·임기 숫자를 14↔10, 7↔5처럼 미세 변경",
            "국가경찰위원회와 자치경찰위원회의 권한을 뒤바꿔 출제",
            "재량처분과 기속처분의 법적 효과를 바꿔 출제",
            "신뢰보호 요건(공적견해표명/귀책사유)을 누락한 함정",
            "징계와 소청심사 절차의 기한 숫자를 바꿔 출제",
        ],
        .general: [
            "조항 번호의 한 자리 숫자만 바꾸어 함정 출제",
            "결론(유죄/무죄, 위법/적법, 인정/부정)을 반대로 진술",
            "한정사(반드시/항상/모든) 강도를 한 단계 올려 단정",
        ],
    ]

    /// 도메인에 따라 함정 카탈로그에서 N개를 무작위로 뽑아 반환.
    static func sampledTraps(for domain: Domain, count: Int = 2) -> [String] {
        let pool = trapCatalog[domain] ?? trapCatalog[.general] ?? []
        guard !pool.isEmpty else { return [] }
        return Array(pool.shuffled().prefix(count))
    }

    // MARK: - Decision Hints (LLM 프롬프트 주입용)

    /// 도메인 분류 결과와 함정 카탈로그를 결합해 LLM 의 OX 프롬프트에 넣을
    /// `decisionHints` 배열을 생성한다. 최대 3개.
    static func buildDecisionHints(
        text: String,
        keywords: [String],
        userWeakKeywords: [String] = []
    ) -> [String] {
        let result = classify(text: text, keywords: keywords)
        var hints: [String] = []

        switch result.domain {
        case .criminalProcedure:
            hints.append("강제처분/임의수사부터 먼저 분기, 그 다음 영장 원칙 확인")
            hints.append("증거 문제는 위법수집-전문법칙-자백법칙 순서 점검")
        case .criminalLaw:
            hints.append("구성요건-위법성-책임 3단 구조로 쟁점 위치 확인")
            hints.append("정당방위/긴급피난, 미수/불능미수 등 쌍 개념 분리")
        case .constitutional:
            hints.append("제한된 기본권 특정 후 과잉금지 4단계 또는 평등심사로 분기")
        case .policeAdministrative:
            hints.append("위원회 구성·기한 숫자와 재량/기속을 동시에 확인")
        case .general:
            hints.append("문제 유형을 10초 안에 과목(형법/형소법/헌법/경찰학)으로 먼저 분류")
        }

        // 함정 카탈로그 1~2개 무작위 추가 — 동일 판례에서도 매번 다른 함정 학습
        let traps = sampledTraps(for: result.domain, count: 1)
        hints.append(contentsOf: traps)

        // 사용자가 자주 틀린 키워드가 있으면 1줄 개인화 힌트 추가
        if !userWeakKeywords.isEmpty {
            let weak = userWeakKeywords.prefix(2).joined(separator: ", ")
            hints.append("사용자가 자주 헷갈리는 개념: \(weak) — 해당 분기 문항 1개 포함")
        }

        // 신뢰도 낮으면 혼합 표시 힌트
        if result.confidence < 0.6, result.domain != .general {
            if let runner = result.runnerUp {
                hints.append("\(result.domain.label)·\(runner.label) 혼합 가능성 — 둘 중 어느 분기인지 먼저 확정")
            }
        }

        return Array(hints.prefix(3))
    }

    // MARK: - 개인화 (오답 기록 기반)

    /// 오답 기록(WrongQuizRecord)들의 `subject` 와 메모 텍스트에서
    /// 사용자가 자주 헷갈리는 키워드 상위 N개를 추출.
    /// LegalIssueDictionary 와 매칭되는 항목만 채택.
    static func weakKeywords(from records: [WrongQuizRecord], topK: Int = 3) -> [String] {
        var freq: [String: Int] = [:]
        for r in records {
            let blob = [r.subject ?? "", r.userMemo ?? "", r.question]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let detected = LegalIssueDictionary.detect(in: blob)
            for k in detected.direct {
                freq[k, default: 0] += 1
            }
        }
        return freq
            .filter { $0.value >= 1 }
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { $0.key }
    }
}
