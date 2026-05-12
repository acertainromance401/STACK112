import Foundation

/// 사진 OCR/paste 입력을 IR/RAG 단계로 넘기기 전에 정제하는 전처리 파이프라인.
///
/// 처리 케이스:
///   1) **잘린 문장 stitch** — 사진 N의 마지막 라인이 종결 부호 없이 끝나고,
///       사진 N+1의 첫 라인이 조사/어미/소문자로 시작하면 두 페이지를 한 문장으로 결합.
///   2) **페이지 간 중복 라인 제거** — 같은 라인이 서로 다른 페이지에서 반복되면 한 번만 유지.
///       portal.scourt.go.kr 페이지를 여러 장 캡쳐했을 때 헤더/푸터/사건번호 행이 매 페이지마다 등장하는 문제 회피.
///   3) **헤더/푸터/상태바 잡음 제거** — `03:48`, `1/12`, `대법원 종합법률정보`, URL, 페이지 번호 등.
///   4) **빈 라인 압축** — 연속 줄바꿈을 하나로.
///
/// 두 진입점:
///   - `mergePages([String])`: 사진 여러 장의 OCR 결과 배열 입력. cross-page 처리까지 수행.
///   - `cleanSinglePass(_:)`: 이미 결합된 텍스트(paste 포함) 단일 입력. 페이지 간 처리는 생략하고 라인 단위 정제만.
enum OCRTextCleaner {

    private struct PageChunk {
        var originalIndex: Int
        var lines: [String]
        var titleScore: Int
        var sectionScore: Int
    }

    /// 여러 사진의 OCR 결과를 하나의 텍스트로 안전하게 결합한다.
    /// 사진 순서는 기본적으로 보존하되, 제목/메타 페이지가 뒤에 붙은 경우는 앞쪽으로 재배치한 뒤
    /// 페이지 간 stitch / dedupe / 헤더 제거를 수행한다.
    static func mergePages(_ pages: [String]) -> String {
        // 1) 페이지별로 라인 정제 후 의미 라인만 남긴다.
        let chunks = reorderPagesIfNeeded(pages.enumerated().map { idx, page in
            PageChunk(
                originalIndex: idx,
                lines: rawLines(in: page).filter { !isNoiseLine($0) },
                titleScore: 0,
                sectionScore: 0
            )
        })
        let cleanedPages = chunks.map { $0.lines }.filter { !$0.isEmpty }
        guard !cleanedPages.isEmpty else { return "" }

        // 2) cross-page 중복 라인 인덱스 결정 — 동일 라인이 ≥2 페이지에 등장하면 헤더/푸터로 보고 모두 제거하지 않고,
        //    각 페이지에서 "첫 등장만" 살린다. 같은 페이지 안의 반복은 그대로 유지(원문 의도 보존).
        var globalSeen: [String: Int] = [:]   // normalized line → page index of first occurrence
        var deduped: [[String]] = []
        for (pageIdx, lines) in cleanedPages.enumerated() {
            var kept: [String] = []
            for line in lines {
                let key = normalizeForDedup(line)
                if key.count < 6 {
                    // 너무 짧은 라인은 dedupe 대상에서 제외(잘못된 머지 방지)
                    kept.append(line)
                    continue
                }
                if let firstPage = globalSeen[key], firstPage != pageIdx {
                    // 다른 페이지에서 이미 등장 — 헤더/푸터로 추정해 스킵
                    continue
                }
                globalSeen[key] = pageIdx
                kept.append(line)
            }
            deduped.append(kept)
        }

        // 3) 페이지 간 잘린 문장 stitch — 페이지 N의 마지막 라인 + N+1의 첫 라인을 한 문장으로 합칠지 결정.
        var merged: [String] = []
        for (idx, lines) in deduped.enumerated() {
            guard !lines.isEmpty else { continue }
            if idx == 0 {
                merged.append(contentsOf: lines)
                continue
            }
            // N+1 페이지 첫 라인을 직전 페이지 마지막 라인과 stitch 할 수 있는지 검사
            let prevTail = merged.last ?? ""
            let curHead = lines.first ?? ""
            if shouldStitchAcrossPages(prevTail: prevTail, curHead: curHead) {
                merged[merged.count - 1] = prevTail + " " + curHead
                merged.append(contentsOf: lines.dropFirst())
            } else {
                merged.append(contentsOf: lines)
            }
        }

        // 4) 같은-문장 중복(연속) 제거 — stitch 결과로 중복이 생긴 경우 정리
        var collapsed: [String] = []
        for line in merged {
            if let last = collapsed.last, normalizeForDedup(last) == normalizeForDedup(line) { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n")
    }

    /// paste 또는 이미 결합된 텍스트 단일 입력을 라인 단위로 정제.
    /// `mergePages`와 같은 헤더/잡음 제거 규칙을 적용하지만, cross-page stitch는 수행하지 않는다.
    static func cleanSinglePass(_ text: String) -> String {
        let lines = rawLines(in: text).filter { !isNoiseLine($0) }
        // 같은 라인 중복(연속/비연속) 한 번만 유지 — paste 시 사용자가 두 번 붙여넣은 경우 대비
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let key = normalizeForDedup(line)
            if key.count >= 6 {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Internals

    /// 텍스트를 라인으로 split 하고 각 라인의 trim + 길이 필터 적용.
    /// 빈 라인 제거, 1자짜리 잔재 라인 제거.
    private static func rawLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 사용자가 제목 페이지를 마지막에 선택해도 본문 앞에 오도록 보정한다.
    ///
    /// 강한 제목 페이지 신호:
    /// - 법원 + 선고일 + 사건번호/전원합의체
    /// - `[모해위증]`, `〈...사건〉` 같은 제목/사건 설명 블록
    /// - 반대로 `【판시사항】`, `【판결요지】` 등 섹션 헤더가 많으면 본문 페이지로 본다.
    ///
    /// 정책:
    /// - 기본은 원래 순서 유지
    /// - 첫 페이지가 강한 제목 페이지가 아닌데, 뒤쪽에 강한 제목 페이지가 있으면
    ///   그 페이지들만 앞쪽으로 stable move
    private static func reorderPagesIfNeeded(_ chunks: [PageChunk]) -> [PageChunk] {
        let scored = chunks.map { chunk -> PageChunk in
            var updated = chunk
            updated.titleScore = computeTitleScore(lines: chunk.lines)
            updated.sectionScore = computeSectionScore(lines: chunk.lines)
            return updated
        }
        guard !scored.isEmpty else { return chunks }

        let first = scored[0]
        let firstIsStrongTitle = first.titleScore >= 6 && first.sectionScore <= 1
        if firstIsStrongTitle { return scored }

        let promoted = scored.filter { $0.titleScore >= 6 && $0.sectionScore <= 1 }
        guard !promoted.isEmpty else { return scored }

        let promotedIndexes = Set(promoted.map(\.originalIndex))
        let remainder = scored.filter { !promotedIndexes.contains($0.originalIndex) }
        return promoted + remainder
    }

    private static func computeTitleScore(lines: [String]) -> Int {
        var score = 0
        for line in lines {
            if line.range(of: #"(대법원|헌법재판소|고등법원|지방법원).*(선고|결정)"#, options: .regularExpression) != nil {
                score += 4
            }
            if line.range(of: #"\d{2,4}\s*[가-힣]{1,3}\s*\d+"#, options: .regularExpression) != nil {
                score += 3
            }
            if line.contains("전원합의체") { score += 2 }
            if line.range(of: #"^\[\s*[가-힣·]{2,20}\s*\]$"#, options: .regularExpression) != nil {
                score += 2
            }
            if line.range(of: #"^[〈<].{4,80}사건[〉>]$"#, options: .regularExpression) != nil {
                score += 2
            }
        }
        return score
    }

    private static func computeSectionScore(lines: [String]) -> Int {
        var score = 0
        for line in lines {
            if line.range(of: #"(판시사항|판결요지|결정요지|참조조문|참조판례|전문|이유|주문)"#, options: .regularExpression) != nil {
                score += 1
            }
        }
        return score
    }

    /// dedupe 비교용 normalize — 모든 공백 제거 + 소문자화.
    /// 표시용이 아닌 비교 키 생성용이므로 부호/괄호도 모두 제거.
    private static func normalizeForDedup(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)
         .lowercased()
    }

    /// 라인이 OCR 헤더/푸터/상태바/페이지번호/URL 같은 의미없는 잡음인지 판정.
    /// 보수적으로(빠뜨리는 쪽으로) 판정 — 의심스러우면 false 반환.
    private static func isNoiseLine(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return true }
        // 1) URL/도메인
        if s.range(of: #"^https?://"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^www\."#, options: .regularExpression) != nil { return true }
        if s.contains("portal.scourt.go.kr") && s.count <= 50 { return true }
        // 2) 시계/배터리 등 상태바 — "03:47", "13:48" 등 단독
        if s.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
        // 3) 페이지 번호 — "1 / 12", "p. 3", "- 3 -" 같은 단독 라인
        if s.range(of: #"^\d{1,3}\s*/\s*\d{1,3}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[-—]\s*\d{1,4}\s*[-—]$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^(p\.?|page)\s*\d+$"#, options: .caseInsensitive) != nil { return true }
        // 4) 사이트 헤더 — "대법원 종합법률정보", "판례 검색" 단독
        let knownHeaders: Set<String> = [
            "대법원 종합법률정보", "판례 검색", "판례검색", "종합법률정보",
            "대한민국 법원", "법제처", "국가법령정보센터"
        ]
        if knownHeaders.contains(s) { return true }
        // 5) 한 글자만 있는 라인 — OCR 잔재
        if s.count <= 1 { return true }
        // 6) 숫자/기호만으로 이루어진 라인 — 페이지 번호 변형
        if s.range(of: #"^[\d\s\.\-:_/]+$"#, options: .regularExpression) != nil && s.count <= 12 {
            return true
        }
        return false
    }

    /// 페이지 N의 꼬리 라인과 페이지 N+1의 머리 라인이 같은 문장의 일부인지 판정.
    /// 사진 N이 종결부 없이 잘렸을 때 사진 N+1의 첫 라인을 이어붙여 IR/LLM에 한 문장으로 전달.
    private static func shouldStitchAcrossPages(prevTail: String, curHead: String) -> Bool {
        let prev = prevTail.trimmingCharacters(in: .whitespaces)
        let cur = curHead.trimmingCharacters(in: .whitespaces)
        guard !prev.isEmpty, !cur.isEmpty else { return false }

        // 1) 이전 페이지 마지막이 종결 부호로 끝났으면 stitch 금지.
        let terminalSuffixes = [".", "?", "!", "。", "다", "라", "요", "오", "음", "임", "함",
                                "사례", "사례.", "기각한다", "파기한다"]
        if terminalSuffixes.contains(where: { prev.hasSuffix($0) }) { return false }
        // 단, "다.", "라." 처럼 종결 부호 + 마침표는 위에서 잡힘.

        // 2) 이전 라인이 섹션 헤더("【판시사항】" 등)면 stitch 금지.
        if prev.range(of: #"^[【\[]?\s*(판시사항|판결요지|결정요지|참조조문|참조판례|이\s*유|주\s*문)\s*[】\]]?\s*$"#,
                      options: .regularExpression) != nil {
            return false
        }

        // 3) 다음 라인이 새로운 섹션 헤더로 시작하면 stitch 금지.
        if cur.range(of: #"^[【\[]?\s*(판시사항|판결요지|결정요지|참조조문|참조판례|이\s*유|주\s*문)"#,
                     options: .regularExpression) != nil {
            return false
        }

        // 4) 다음 라인이 새로운 항목 번호로 시작하면 stitch 금지 ("[1]", "[2]", "1.", "가." 등).
        if cur.range(of: #"^(\[\d+\]|\(\d+\)|\d{1,2}\.\s|[가-힣]\.\s)"#, options: .regularExpression) != nil {
            return false
        }

        // 5) 다음 라인이 한국어 조사/어미/접속사로 시작하면 stitch 강한 신호.
        let continuationStarters = [
            "는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "에 ", "에서 ", "으로 ", "로 ",
            "및 ", "또는 ", "그리고 ", "그러나 ", "다만 ", "한편 ",
            "하는 ", "되는 ", "있는 ", "없는 ", "한 ", "된 ",
            "여부", "(적극)", "(소극)"
        ]
        if continuationStarters.contains(where: { cur.hasPrefix($0) }) { return true }

        // 6) 이전 라인이 조사/어미로 끝나면 (마침표 없이) — 본문 계속 강한 신호.
        let openSuffixes = [
            "및", "또는", "그리고", "그러나",
            "는", "은", "이", "가", "을", "를", "의", "에", "에서",
            "하여", "되어", "있어", "없어",
            "하고", "되고", "있고", "없고",
            "하며", "되며", "있으며", "없으며"
        ]
        if openSuffixes.contains(where: { prev.hasSuffix($0) }) { return true }

        // 7) 이전이 마침표 없이 끝났고 다음이 대괄호/숫자로 시작하지 않으면 보수적으로 stitch.
        let prevTerminators: Set<Character> = [".", "?", "!", "。", ")", "]", "】"]
        let curHardStarters: Set<Character> = ["【", "[", "(", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        let prevEndsSoft = !(prev.last.map { prevTerminators.contains($0) } ?? false)
        let curStartsHard = (cur.first.map { curHardStarters.contains($0) } ?? false)
        if prevEndsSoft && !curStartsHard {
            // 추가 안전망 — 두 라인 모두 충분히 길어야 stitch
            if prev.count >= 8 && cur.count >= 4 { return true }
        }

        return false
    }
}
