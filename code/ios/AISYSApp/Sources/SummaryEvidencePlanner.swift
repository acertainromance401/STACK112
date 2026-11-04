import Foundation

// Evaluation-only planner; production summary callers keep their existing path.
enum SummaryEvidencePlanner {
    enum Role: String, Codable, CaseIterable {
        case principle, facts, reasoning, disposition

        var label: String {
            switch self {
            case .principle: return "법리"
            case .facts: return "사실"
            case .reasoning: return "판단"
            case .disposition: return "주문"
            }
        }

        var query: String {
            switch self {
            case .principle: return "법리 원칙: 의무 변경 또는 새로운 조건 부과는 언제 허용되고 언제 금지되는가?"
            case .facts: return "구체적 사실: 이 사건에서 부과한 의무 또는 추가 조건의 내용은 무엇인가?"
            case .reasoning: return "판단 이유: 법원은 이 사건 처분 또는 조건이 허용되지 않는다고 본 근거를 어떻게 설명하는가?"
            case .disposition: return ""
            }
        }
    }

    struct Evidence: Codable {
        let role: Role
        let chunk: RAGChunk
        let selectedSentenceStartUTF16: Int
        let expandedPreviousSentence: Bool
    }

    struct Search: Codable {
        let role: Role
        let result: RAGSearchResult
    }

    struct Plan: Codable {
        let mode: RAGRetrievalMode
        let evidence: [Evidence]
        let searches: [Search]
    }

    private struct Sentence {
        let section: String
        let sectionIndex: Int
        let range: NSRange
        let text: String
    }

    static func plan(document: RAGDocument, mode: RAGRetrievalMode, retriever: RAGRetriever) throws -> Plan {
        guard mode != .currentOnly else {
            throw RAGError.invalidInput("문장 보존 평가는 키워드·의미·하이브리드 검색만 지원합니다.")
        }
        let sentences = try sourceSentences(document.text)
        let chunkCount = try RAGChunker.chunks(for: document).count
        guard chunkCount > 0 else { throw RAGError.invalidInput("요약할 원문이 없습니다.") }
        var evidence: [Evidence] = []
        var searches: [Search] = []
        var selectedTexts = Set<String>()
        for role in Role.allCases {
            let candidates = sentences.filter {
                switch role {
                case .principle: return $0.section == "판결요지" || $0.section == "결정요지"
                case .facts, .reasoning: return $0.section == "이유"
                case .disposition: return $0.section == "주문"
                }
            }
            guard !candidates.isEmpty else {
                throw RAGError.unavailable("\(role.label) 영역에 완결된 원문 문장이 없습니다.")
            }
            let sentence: Sentence
            if role == .disposition {
                guard candidates.count == 1, let first = candidates.first else {
                    throw RAGError.unavailable("이 소규모 평가에서는 한 문장 주문만 지원합니다. 복수 주문을 조용히 생략하지 않습니다.")
                }
                sentence = first
            } else {
                let result = try retriever.retrieveWithin(document: document, query: role.query, mode: mode, topK: chunkCount)
                guard result.effectiveMode == mode, result.warnings.isEmpty,
                      mode == .keyword || result.semanticScoredChunkCount == result.chunkCount else {
                    throw RAGError.unavailable("평가 검색이 부분 실행되거나 대체되었습니다: \(result.warnings.joined(separator: "; "))")
                }
                searches.append(Search(role: role, result: result))
                var match: Sentence?
                for hit in result.hits {
                    let hitRange = NSRange(location: hit.chunk.startUTF16,
                                           length: hit.chunk.endUTF16 - hit.chunk.startUTF16)
                    let overlapping = candidates.filter {
                        NSIntersectionRange($0.range, hitRange).length > 0
                            && !selectedTexts.contains(normalized($0.text))
                    }.sorted {
                        let left = NSIntersectionRange($0.range, hitRange).length
                        let right = NSIntersectionRange($1.range, hitRange).length
                        return left != right ? left > right : $0.range.location < $1.range.location
                    }
                    if let first = overlapping.first { match = first; break }
                }
                guard let match else {
                    throw RAGError.unavailable("\(role.label)의 중복되지 않는 완결 문장을 찾지 못했습니다.")
                }
                sentence = match
            }
            var range = sentence.range
            let needsContext = ["따라서", "그러므로", "이는", "이러한", "이에 따라"].contains {
                sentence.text.hasPrefix($0)
            }
            if role == .reasoning, needsContext,
               let previous = sentences.last(where: {
                   $0.sectionIndex == sentence.sectionIndex && NSMaxRange($0.range) <= sentence.range.location
               }) {
                range = NSUnionRange(previous.range, sentence.range)
            }
            let original = document.text as NSString
            let text = original.substring(with: range)
            selectedTexts.insert(normalized(sentence.text))
            let chunk = RAGChunk(
                id: "\(document.id):\(document.fingerprint.prefix(12)):\(range.location)-\(NSMaxRange(range))",
                documentID: document.id, documentFingerprint: document.fingerprint,
                caseNumber: document.caseNumber, title: document.title, sourceKind: document.sourceKind,
                sourceURL: document.sourceURL, startUTF16: range.location, endUTF16: NSMaxRange(range), text: text)
            evidence.append(Evidence(role: role, chunk: chunk, selectedSentenceStartUTF16: sentence.range.location,
                                     expandedPreviousSentence: range != sentence.range))
        }
        return Plan(mode: mode, evidence: evidence, searches: searches)
    }

    static func prompt(document: RAGDocument, plan: Plan) -> String {
        let evidence = plan.evidence.map { "[\($0.role.label)]\n\($0.chunk.text)" }.joined(separator: "\n")
        return """
        다음 원문 근거만으로 한국어 판례 요약을 작성하라.
        각 항목은 짧은 한 문장. 부정·조건·구체적 사실·처분 결과를 보존하라.
        사건번호나 인용목록을 반복하지 말고, 없는 사실을 만들지 말라.
        사건번호: \(document.caseNumber)
        \(evidence)
        [출력 형식]
        법리:
        사실:
        판단:
        주문:
        """
    }

    private static func sourceSentences(_ text: String) throws -> [Sentence] {
        let original = text as NSString
        let markers = try NSRegularExpression(pattern: "【([^】]+)】").matches(
            in: text, range: NSRange(location: 0, length: original.length))
        let endings = try NSRegularExpression(pattern: "(?<![0-9])[.!?。](?=\\s|$)|\\n")
        var result: [Sentence] = []
        for (index, marker) in markers.enumerated() {
            let section = original.substring(with: marker.range(at: 1)).filter { !$0.isWhitespace }
            guard ["판결요지", "결정요지", "이유", "주문"].contains(section) else { continue }
            let start = NSMaxRange(marker.range)
            let end = index + 1 < markers.count ? markers[index + 1].range.location : original.length
            let sectionRange = NSRange(location: start, length: end - start)
            let boundaries = endings.matches(in: text, range: sectionRange).map { NSMaxRange($0.range) } + [end]
            var cursor = start
            for boundary in boundaries {
                let rawRange = NSRange(location: cursor, length: boundary - cursor)
                cursor = boundary
                guard let swiftRange = Range(rawRange, in: text) else {
                    throw RAGError.invalidInput("원문 문장 범위가 유효하지 않습니다.")
                }
                let raw = text[swiftRange]
                guard let first = raw.firstIndex(where: { !$0.isWhitespace }),
                      let last = raw.lastIndex(where: { !$0.isWhitespace }) else { continue }
                let trimmed = first..<raw.index(after: last)
                let sentence = String(text[trimmed])
                guard let lastCharacter = sentence.last, ".!?。".contains(lastCharacter) else { continue }
                result.append(Sentence(section: section, sectionIndex: index,
                                       range: NSRange(trimmed, in: text), text: sentence))
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}
