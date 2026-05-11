import Foundation
import SwiftData

/// OCR로 스캔한 판례를 기기에 영구 저장하는 SwiftData 모델
@Model
final class ScannedCase {
    // MARK: - 식별자
    var id: String

    // MARK: - 원문 / IR 결과
    var ocrRawText: String          // OCR 추출 전문
    var keywords: [String]          // IR 키워드
    var keySentences: String        // TextRank 핵심 문장

    // MARK: - LLM 요약 결과 (생성된 경우에만 저장)
    var oneLineSummary: String?
    var keyIssue: String?
    var rulingPoint: String?
    var examTakeaway: String?

    // MARK: - 메타
    var caseName: String            // OCR 텍스트 앞 40자 기반 제목
    var scannedAt: Date

    init(
        id: String = UUID().uuidString,
        ocrRawText: String,
        keywords: [String],
        keySentences: String,
        caseName: String,
        oneLineSummary: String? = nil,
        keyIssue: String? = nil,
        rulingPoint: String? = nil,
        examTakeaway: String? = nil
    ) {
        self.id = id
        self.ocrRawText = ocrRawText
        self.keywords = keywords
        self.keySentences = keySentences
        self.caseName = caseName
        self.oneLineSummary = oneLineSummary
        self.keyIssue = keyIssue
        self.rulingPoint = rulingPoint
        self.examTakeaway = examTakeaway
        self.scannedAt = Date()
    }

    /// SwiftData 레코드 → APICase 변환 (ViewModel 재사용)
    func toAPICase() -> APICase {
        APICase(
            id: id,
            caseNumber: caseName,
            caseName: caseName,
            courtName: "스캔 문서",
            subject: keywords.prefix(3).joined(separator: " · "),
            issueSummary: keyIssue ?? keySentences,
            holdingSummary: rulingPoint,
            examPoints: examTakeaway ?? keywords.prefix(5).joined(separator: ", "),
            sourceUrl: nil
        )
    }

    /// 로컬 검색 corpus 전용 변환.
    /// `toAPICase()` 가 detail UI에서 그대로 표시되는 데 반해, 검색용은
    /// OCR 원문(ocrRawText) 의 일부를 issueSummary 에 합쳐 검색 hit 률을 올린다.
    func toSearchableAPICase() -> APICase {
        let baseSummary = keyIssue ?? keySentences
        // OCR 원문 앞 1500자까지를 검색 corpus 본문에 포함 (UI 노출 X)
        let rawSnippet = String(ocrRawText.prefix(1500))
        let combined = [baseSummary, rawSnippet]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return APICase(
            id: id,
            caseNumber: caseName,
            caseName: caseName,
            courtName: "스캔 문서",
            subject: keywords.prefix(8).joined(separator: " · "),
            issueSummary: combined,
            holdingSummary: rulingPoint,
            examPoints: examTakeaway ?? keywords.prefix(8).joined(separator: ", "),
            sourceUrl: nil
        )
    }
}

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
}
