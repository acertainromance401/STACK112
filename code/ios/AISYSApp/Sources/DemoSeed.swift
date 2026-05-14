#if DEBUG
import Foundation
import SwiftData

/// 스크린샷·데모용 시드 데이터.
/// 시뮬레이터 + DEBUG 빌드 + `STACK112_DEMO_SEED=1` 환경변수가 모두 만족될 때만
/// 1회 주입한다. 실기기·Release 빌드에는 절대 포함되지 않는다.
enum DemoSeed {
    static func seedIfNeeded(context: ModelContext) {
        #if targetEnvironment(simulator)
        // 시뮬레이터 DEBUG 빌드에서, 데이터가 비어있을 때만 자동 주입.
        // 실기기 / Release 에는 #if DEBUG 외부 가드로 컴파일 자체에서 제외.
        let descriptor = FetchDescriptor<ScannedCase>()
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            return
        }
        #else
        return
        #endif

        let now = Date()
        for (i, row) in samples.enumerated() {
            let case_ = ScannedCase(
                ocrRawText: row.raw,
                keywords: row.keywords,
                keySentences: row.keySentences,
                caseName: row.caseName,
                oneLineSummary: row.summary,
                keyIssue: row.issue,
                rulingPoint: row.ruling,
                examTakeaway: row.takeaway
            )
            // scannedAt 을 과거로 분산 (스택 게이지가 한 번에 채워지지 않은 자연스러운 분포)
            case_.scannedAt = now.addingTimeInterval(TimeInterval(-i * 3600 * 8))
            context.insert(case_)
        }
        try? context.save()
    }

    private struct Sample {
        let caseName: String
        let raw: String
        let keywords: [String]
        let keySentences: String
        let summary: String
        let issue: String
        let ruling: String
        let takeaway: String
    }

    private static let samples: [Sample] = [
        Sample(
            caseName: "대법원 2023다12345 — 주의의무 위반",
            raw: "원고는 보행 중 피고 운전 차량에 의해 상해를 입었다. 피고는 야간 주행 중 전방 주시를 게을리하였고, 횡단보도 부근에서 감속하지 아니하여 사고가 발생하였다.",
            keywords: ["주의의무", "전방주시", "횡단보도", "야간운전"],
            keySentences: "야간 운전자의 전방주시의무 위반 여부가 쟁점.",
            summary: "야간 횡단보도 부근 전방주시의무 위반 인정.",
            issue: "야간 주행 중 횡단보도 부근에서 운전자의 전방주시의무 범위",
            ruling: "횡단보도 부근에서는 보행자 출현 가능성이 높으므로 평소보다 가중된 주의의무 부담.",
            takeaway: "야간 + 횡단보도 = 가중된 주의의무. 면책 어려움."
        ),
        Sample(
            caseName: "헌재 2022헌마567 — 표현의 자유",
            raw: "청구인은 온라인 게시글로 인해 정보통신망법 제70조에 의해 처벌받았다. 청구인은 해당 조항이 표현의 자유를 침해한다고 주장하였다.",
            keywords: ["표현의자유", "정보통신망법", "명예훼손", "과잉금지"],
            keySentences: "명예훼손죄와 표현의 자유의 충돌 — 과잉금지원칙 심사.",
            summary: "정보통신망법 명예훼손 조항 합헌.",
            issue: "사이버 명예훼손 처벌 조항이 표현의 자유를 과도하게 제한하는지",
            ruling: "공익 목적의 비판은 위법성 조각. 입법 목적 정당 + 비례성 충족.",
            takeaway: "공익 vs 사익. 사실 적시와 의견 표명 구분 필수."
        ),
        Sample(
            caseName: "대법원 2024도789 — 정당방위",
            raw: "피고인은 심야 귀가 중 강도의 공격을 받고 반격하여 강도가 부상을 입었다. 검사는 과잉방위로 기소하였다.",
            keywords: ["정당방위", "과잉방위", "현재의부당한침해", "상당성"],
            keySentences: "정당방위와 과잉방위의 경계 — 상당성 판단.",
            summary: "심야 강도 반격, 정당방위 인정.",
            issue: "강도 침해에 대한 반격이 상당성 요건을 충족하는지",
            ruling: "급박한 침해 상황 + 방위 의사 + 상당한 정도 → 정당방위 성립.",
            takeaway: "현재성·부당성·상당성 3요건 필수 암기."
        ),
        Sample(
            caseName: "대법원 2023다98765 — 사용자책임",
            raw: "피고 회사 직원이 업무 중 차량 사고로 원고에게 손해를 입혔다. 원고는 직원과 회사 모두를 상대로 손해배상을 청구하였다.",
            keywords: ["사용자책임", "사무집행관련성", "외형이론", "구상권"],
            keySentences: "사용자책임의 사무집행관련성 판단 — 외형이론.",
            summary: "업무 중 사고 — 사용자책임 인정.",
            issue: "직원의 행위가 사무집행 관련성을 갖는지 — 외형이론",
            ruling: "객관적 외형상 직무 범위 내로 보이면 사무집행관련성 인정.",
            takeaway: "외형이론 — 객관적 외관 기준. 주관적 의사 무관."
        ),
        Sample(
            caseName: "헌재 2023헌가12 — 평등원칙",
            raw: "심판대상조항은 특정 직역에 대해 가입을 의무화하면서 다른 직역에는 선택권을 부여하고 있어 평등원칙 위반 여부가 문제된다.",
            keywords: ["평등원칙", "차별취급", "합리적이유", "엄격심사"],
            keySentences: "직역간 차별 — 합리적 이유의 존부.",
            summary: "직역간 차별 — 합리적 이유 인정, 합헌.",
            issue: "직역간 차별취급에 합리적 이유가 존재하는지",
            ruling: "직역의 특성과 공익 목적을 감안할 때 자의적 차별이 아님.",
            takeaway: "평등심사 — 자의금지 vs 비례원칙 구분."
        ),
        Sample(
            caseName: "대법원 2022다11111 — 채무불이행",
            raw: "원고와 피고는 부동산 매매계약을 체결하였으나, 피고가 잔금일에 소유권이전등기 의무를 이행하지 아니하였다.",
            keywords: ["채무불이행", "이행지체", "동시이행", "해제"],
            keySentences: "쌍무계약에서 동시이행항변권과 이행지체의 관계.",
            summary: "잔금 미이행 — 이행지체 + 해제 인정.",
            issue: "동시이행항변권 행사 가능 여부와 이행지체 성립",
            ruling: "상대방이 이행 제공한 이상 동시이행항변권 소멸. 이행지체 성립.",
            takeaway: "동시이행 → 이행 제공 시점이 핵심."
        ),
        Sample(
            caseName: "대법원 2024다55555 — 손해배상 범위",
            raw: "교통사고 피해자인 원고는 일실수입과 위자료를 청구하였다. 피고는 과실상계와 손익상계를 주장하였다.",
            keywords: ["일실수입", "위자료", "과실상계", "손익상계"],
            keySentences: "일실수입 산정과 과실상계 적용 순서.",
            summary: "일실수입 인정, 과실 30% 상계.",
            issue: "일실수입 산정 기초 + 과실상계 비율",
            ruling: "통계소득 기준 산정 후 과실비율 30% 상계.",
            takeaway: "과실상계는 손해 확정 후 최후 단계."
        ),
        Sample(
            caseName: "헌재 2021헌바99 — 재산권 제한",
            raw: "토지수용에 따른 보상금이 시가에 미치지 못한다는 이유로 청구인은 헌법소원을 제기하였다.",
            keywords: ["재산권", "정당한보상", "공용수용", "시가"],
            keySentences: "공용수용 보상의 정당성 판단 — 시가 기준.",
            summary: "공시지가 기준 보상 합헌.",
            issue: "공시지가 기준 보상이 정당한 보상에 해당하는지",
            ruling: "공시지가는 시가를 합리적으로 반영하는 기준 → 합헌.",
            takeaway: "정당한 보상 = 완전 보상이 원칙."
        ),
        Sample(
            caseName: "대법원 2023도2024 — 죄형법정주의",
            raw: "검사는 피고인을 형법 제○조 위반으로 기소하였으나, 해당 조항의 구성요건이 불명확하다는 주장이 있었다.",
            keywords: ["죄형법정주의", "명확성원칙", "유추해석금지", "포괄위임"],
            keySentences: "구성요건의 명확성 — 통상의 판단능력 기준.",
            summary: "구성요건 명확성 인정 — 유죄.",
            issue: "구성요건이 명확성원칙에 위배되는지",
            ruling: "통상의 판단능력을 가진 자라면 의미 파악 가능 → 명확성 충족.",
            takeaway: "명확성 = 통상인의 예측가능성."
        ),
        Sample(
            caseName: "대법원 2022다77777 — 소멸시효",
            raw: "원고는 10년 전 발생한 채권을 행사하였으나 피고는 소멸시효 완성을 주장하였다.",
            keywords: ["소멸시효", "시효중단", "권리행사", "기산점"],
            keySentences: "소멸시효 기산점과 중단사유 — 권리행사 시점.",
            summary: "시효 완성 — 청구 기각.",
            issue: "소멸시효의 기산점과 중단사유 존부",
            ruling: "권리를 행사할 수 있는 때부터 진행. 중단 사유 없음.",
            takeaway: "기산점 — 권리 행사 가능 시점."
        ),
        Sample(
            caseName: "헌재 2024헌마33 — 적법절차",
            raw: "행정기관의 처분 전 의견청취 절차가 생략되었다는 이유로 적법절차 위반이 다투어졌다.",
            keywords: ["적법절차", "의견청취", "사전통지", "행정처분"],
            keySentences: "행정처분 사전절차의 적법절차원칙 적용.",
            summary: "의견청취 누락 — 위법.",
            issue: "사전 의견청취 누락이 적법절차원칙에 위배되는지",
            ruling: "당사자의 권익에 중대한 영향 → 의견청취 필수.",
            takeaway: "적법절차 = 통지 + 의견 진술 기회."
        ),
        Sample(
            caseName: "대법원 2023다88888 — 부당이득",
            raw: "원고는 착오로 피고 계좌에 송금하였고, 반환을 청구하였다. 피고는 적법한 대가관계가 있다고 주장하였다.",
            keywords: ["부당이득", "법률상원인", "착오송금", "반환의무"],
            keySentences: "착오송금 부당이득 반환청구의 요건.",
            summary: "법률상 원인 없음 — 반환 명령.",
            issue: "착오송금이 부당이득 반환사유에 해당하는지",
            ruling: "법률상 원인 없는 이득 → 반환 의무 인정.",
            takeaway: "부당이득 4요건 — 이득·손실·인과·법률상 원인 부존재."
        )
    ]
}
#endif
