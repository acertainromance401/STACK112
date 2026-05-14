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
    var caseNumber: String?         // 원문에서 추출한 사건번호 (구버전 레코드는 nil 가능)
    var caseName: String            // OCR 텍스트 앞 40자 기반 제목
    var scannedAt: Date

    init(
        id: String = UUID().uuidString,
        ocrRawText: String,
        keywords: [String],
        keySentences: String,
        caseNumber: String? = nil,
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
        self.caseNumber = caseNumber
        self.caseName = caseName
        self.oneLineSummary = oneLineSummary
        self.keyIssue = keyIssue
        self.rulingPoint = rulingPoint
        self.examTakeaway = examTakeaway
        self.scannedAt = Date()
    }

    private var resolvedCaseNumber: String {
        let stored = caseNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        if let range = ocrRawText.range(of: #"\d{2,4}\s*[가-힣]{1,3}\s*\d+"#, options: .regularExpression) {
            return String(ocrRawText[range]).replacingOccurrences(of: " ", with: "")
        }
        return caseName
    }

    private var resolvedCaseName: String {
        let stored = caseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericPartyLabels: Set<String> = [
            "피고인", "원고", "피고", "상고인", "피상고인", "항고인", "피항고인",
            "채무자", "채권자", "신청인", "청구인", "상대방"
        ]

        func isGenericStoredName(_ value: String) -> Bool {
            let cleaned = value.replacingOccurrences(of: "사건", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return genericPartyLabels.contains(cleaned)
        }

        if !stored.isEmpty,
           !isGenericStoredName(stored),
           stored.range(of: #"^\d{2,4}\s*[가-힣]{1,3}\s*\d+$"#, options: .regularExpression) == nil {
            return stored
        }

        if let range = ocrRawText.range(of: #"사\s*건\s*\n\s*\d{2,4}\s*[가-힣]{1,3}\s*\d+\s+([^\n]{2,80})"#, options: .regularExpression) {
            let line = String(ocrRawText[range])
            let extracted = line.replacingOccurrences(of: #"^사\s*건\s*\n\s*\d{2,4}\s*[가-힣]{1,3}\s*\d+\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty && !isGenericStoredName(extracted) { return extracted }
        }

        if let range = ocrRawText.range(of: #"([가-힣A-Za-z0-9·]+?)(?:가|이|은|는)[^\n]{0,80}?문제\s*된\s*사건"#, options: .regularExpression) {
            let matched = String(ocrRawText[range])
            let extracted = matched.replacingOccurrences(of: #"(?:가|이|은|는).*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty && !isGenericStoredName(extracted) { return extracted }
        }

        let normalized = LocalIRPipeline.normalize(ocrRawText)
        let parsed = JudgmentParser.parse(normalized)
        if let issue = parsed.issues.first {
            let trimmed = issue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(32))
            }
        }
        return stored.isEmpty ? resolvedCaseNumber : stored
    }

    /// SwiftData 레코드 → APICase 변환 (ViewModel 재사용)
    func toAPICase() -> APICase {
        APICase(
            id: id,
            caseNumber: resolvedCaseNumber,
            caseName: resolvedCaseName,
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
            caseNumber: resolvedCaseNumber,
            caseName: resolvedCaseName,
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
