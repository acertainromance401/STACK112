import Foundation
import CryptoKit
import OSLog

enum RAGError: LocalizedError {
    case invalidInput(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .unavailable(let message): return message
        }
    }
}

struct RAGDocument: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let caseNumber: String
    let title: String
    let subject: String
    let text: String
    let sourceKind: String
    let sourceURL: String?
    let extractedCase: APICase?

    init(caseItem: APICase, rawText: String? = nil) {
        id = caseItem.id
        caseNumber = caseItem.caseNumber
        title = caseItem.caseName
        subject = caseItem.subject
        let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text = raw.isEmpty
            ? [caseItem.issueSummary, caseItem.holdingSummary, caseItem.examPoints].compactMap { $0 }.joined(separator: "\n")
            : rawText ?? ""
        sourceKind = raw.isEmpty ? "extracted_fields" : "ocr_or_pasted_text"
        sourceURL = caseItem.sourceUrl
        extractedCase = caseItem
    }

    var fingerprint: String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(caseItem: APICase, rawText: String?, documents: [RAGDocument]) -> RAGDocument {
        if let stored = documents.first(where: { $0.id == caseItem.id }) { return stored }
        let current = RAGDocument(caseItem: caseItem, rawText: rawText)
        return documents.first { $0.title == current.title && $0.fingerprint == current.fingerprint } ?? current
    }
}

struct RAGChunk: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let documentID: String
    let documentFingerprint: String
    let caseNumber: String
    let title: String
    let sourceKind: String
    let sourceURL: String?
    let startUTF16: Int
    let endUTF16: Int
    let text: String

    func excerpt(limit: Int) -> RAGChunk {
        let clipped = String(text.prefix(limit))
        return RAGChunk(
            id: id, documentID: documentID, documentFingerprint: documentFingerprint,
            caseNumber: caseNumber, title: title, sourceKind: sourceKind, sourceURL: sourceURL,
            startUTF16: startUTF16, endUTF16: startUTF16 + clipped.utf16.count, text: clipped
        )
    }
}

enum RAGChunker {
    static func chunks(for document: RAGDocument, size: Int = 320, overlap: Int = 64) throws -> [RAGChunk] {
        guard size >= 32, overlap >= 0, overlap < size else {
            throw RAGError.invalidInput("청크 크기는 32자 이상이고 겹침은 크기보다 작아야 합니다.")
        }
        let text = document.text
        let fingerprint = document.fingerprint
        var start = text.startIndex
        var result: [RAGChunk] = []
        while start < text.endIndex {
            let hardEnd = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            var end = hardEnd
            if hardEnd < text.endIndex {
                let boundaryStart = text.index(start, offsetBy: max(overlap + 1, size / 2))
                if let boundary = text[boundaryStart..<hardEnd].lastIndex(where: { "\n.!?。".contains($0) }) {
                    end = text.index(after: boundary)
                }
            }
            let content = String(text[start..<end])
            let lower = start.utf16Offset(in: text)
            let upper = end.utf16Offset(in: text)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(RAGChunk(
                    id: "\(document.id):\(fingerprint.prefix(12)):\(lower)-\(upper)",
                    documentID: document.id, documentFingerprint: fingerprint,
                    caseNumber: document.caseNumber, title: document.title,
                    sourceKind: document.sourceKind, sourceURL: document.sourceURL,
                    startUTF16: lower, endUTF16: upper, text: content
                ))
            }
            guard end < text.endIndex else { break }
            start = text.index(end, offsetBy: -min(overlap, text.distance(from: start, to: end) - 1))
        }
        return result
    }
}

enum RAGRetrievalMode: String, Codable, CaseIterable, Identifiable {
    case currentOnly, keyword, hybrid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .currentOnly: return "현재 판례만"
        case .keyword: return "키워드"
        case .hybrid: return "키워드 + 의미"
        }
    }
}

struct RAGHit: Codable, Identifiable {
    let chunk: RAGChunk
    let score: Double
    let keywordRank: Int?
    let semanticRank: Int?
    var id: String { chunk.id }
}

struct RAGSearchResult: Codable {
    let hits: [RAGHit]
    let requestedMode: RAGRetrievalMode
    let effectiveMode: RAGRetrievalMode
    let warnings: [String]
    let chunkCount: Int
    let semanticScoredChunkCount: Int
    let semanticModelIdentity: [String: String]
}

struct RAGRetriever {
    private let semanticScorer: (String, [String]) throws -> RAGSemanticResult
    private static let logger = Logger(subsystem: "com.acertainromance401.aisys", category: "RAGRetriever")

    init(provider: GGUFEmbeddingProvider = .shared) {
        semanticScorer = { query, texts in try provider.scores(query: query, documents: texts) }
    }

    init(semanticScorer: @escaping (String, [String]) -> [Double?]) {
        self.semanticScorer = { query, texts in
            RAGSemanticResult(scores: semanticScorer(query, texts), identity: ["provider": "injected-test-scorer"], warnings: [])
        }
    }

    func retrieve(query: String, target: RAGDocument, documents: [RAGDocument],
                  mode: RAGRetrievalMode, topK: Int = 3) throws -> RAGSearchResult {
        guard topK > 0, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RAGError.invalidInput("검색 질문은 비어 있지 않아야 하며 topK는 양수여야 합니다.")
        }
        guard Set(documents.map(\.id)).count == documents.count else {
            throw RAGError.invalidInput("검색 코퍼스 문서 ID가 중복되었습니다.")
        }
        if mode == .currentOnly {
            return RAGSearchResult(hits: [], requestedMode: mode, effectiveMode: mode, warnings: [],
                                   chunkCount: 0, semanticScoredChunkCount: 0, semanticModelIdentity: [:])
        }
        var seenCaseNumbers = Set<String>()
        let candidates = documents.filter {
            $0.id != target.id && !sameCaseNumber($0.caseNumber, target.caseNumber)
                && !($0.title == target.title && $0.fingerprint == target.fingerprint)
        }.sorted { $0.id < $1.id }.filter {
            guard let number = LocalCaseSearchEngine.normalizedCaseNumber($0.caseNumber) else { return true }
            return seenCaseNumbers.insert(number).inserted
        }
        let chunks = try candidates.flatMap { try RAGChunker.chunks(for: $0) }
        let corpus = chunks.map { chunk in
            APICase(id: chunk.id, caseNumber: chunk.caseNumber, caseName: chunk.title, courtName: "",
                    subject: candidates.first { $0.id == chunk.documentID }?.subject ?? "",
                    issueSummary: chunk.text, holdingSummary: nil, examPoints: nil, sourceUrl: chunk.sourceURL)
        }
        var keywordIDs = LocalCaseSearchEngine.search(query: query, in: corpus, limit: corpus.count).map(\.id)
        let exactIDs = chunks.filter { containsCaseNumber(query, $0.caseNumber) }.map(\.id)
        keywordIDs = exactIDs + keywordIDs.filter { !exactIDs.contains($0) }
        let keywordRanks = Dictionary(uniqueKeysWithValues: keywordIDs.enumerated().map { ($0.element, $0.offset + 1) })
        var scores: [Double?] = Array(repeating: nil, count: chunks.count)
        var semanticIdentity: [String: String] = [:]
        var warnings: [String] = []
        if mode == .hybrid && !chunks.isEmpty {
            do {
                let result = try semanticScorer(query, chunks.map(\.text))
                scores = result.scores
                semanticIdentity = result.identity
                warnings += result.warnings
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = "의미 검색 실패: \(error.localizedDescription)"
                warnings.append(message)
                semanticIdentity = ["status": "unavailable", "reason": error.localizedDescription]
                Self.logger.error("\(message, privacy: .public)")
            }
        }
        guard scores.count == chunks.count else {
            throw RAGError.invalidInput("의미 검색 점수 개수가 청크 개수와 일치하지 않습니다.")
        }
        guard scores.compactMap({ $0 }).allSatisfy(\.isFinite) else {
            throw RAGError.invalidInput("의미 검색 점수에 유효하지 않은 값이 있습니다.")
        }
        let semanticAvailable = scores.contains { $0 != nil }
        let semanticIDs = chunks.indices.filter { (scores[$0] ?? 0) > 0.30 }.sorted {
            if scores[$0] != scores[$1] { return (scores[$0] ?? 0) > (scores[$1] ?? 0) }
            return chunks[$0].id < chunks[$1].id
        }.map { chunks[$0].id }
        let semanticRanks = Dictionary(uniqueKeysWithValues: semanticIDs.enumerated().map { ($0.element, $0.offset + 1) })
        let effective: RAGRetrievalMode = mode == .hybrid && semanticAvailable ? .hybrid : .keyword
        let ranked = chunks.compactMap { chunk -> RAGHit? in
            let lexical = keywordRanks[chunk.id]
            let semantic = effective == .hybrid ? semanticRanks[chunk.id] : nil
            guard lexical != nil || semantic != nil else { return nil }
            let score = lexical.map { 1.0 / Double(60 + $0) } ?? 0
            let fused = score + (semantic.map { 1.0 / Double(60 + $0) } ?? 0)
                + (exactIDs.contains(chunk.id) ? 1 : 0)
            return RAGHit(chunk: chunk, score: fused, keywordRank: lexical, semanticRank: semantic)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
        var perDocument: [String: Int] = [:]
        let diverse = ranked.filter {
            let count = perDocument[$0.chunk.documentID, default: 0]
            guard count < 2 else { return false }
            perDocument[$0.chunk.documentID] = count + 1
            return true
        }
        if mode == .hybrid && !semanticAvailable && !chunks.isEmpty {
            warnings.append("임베딩을 사용할 수 없어 키워드 검색으로 실행했습니다. 하이브리드 실험으로 집계하지 마세요.")
        }
        if mode == .hybrid && semanticAvailable && scores.contains(where: { $0 == nil }) {
            warnings.append("일부 청크의 의미 벡터가 없어 해당 청크는 키워드 점수만 사용했습니다.")
        }
        if diverse.isEmpty { warnings.append("검색된 참고 근거가 없습니다. 현재 판례 E0만으로 분석합니다.") }
        return RAGSearchResult(
            hits: Array(diverse.prefix(topK)), requestedMode: mode, effectiveMode: effective,
            warnings: warnings, chunkCount: chunks.count, semanticScoredChunkCount: scores.compactMap { $0 }.count,
            semanticModelIdentity: semanticIdentity
        )
    }

    private func sameCaseNumber(_ a: String, _ b: String) -> Bool {
        guard let number = LocalCaseSearchEngine.normalizedCaseNumber(a) else { return false }
        return number == LocalCaseSearchEngine.normalizedCaseNumber(b)
    }

    private func containsCaseNumber(_ query: String, _ number: String) -> Bool {
        guard let compact = LocalCaseSearchEngine.normalizedCaseNumber(number) else { return false }
        let pattern = "(?<![0-9])" + NSRegularExpression.escapedPattern(for: compact) + "(?![0-9])"
        return query.filter { !$0.isWhitespace }.range(of: pattern, options: .regularExpression) != nil
    }
}

struct RAGEvidence: Codable, Identifiable {
    let id: String
    let chunk: RAGChunk
}

struct RAGClaim: Codable, Identifiable {
    let id: Int
    let text: String
    let citationIDs: [String]
    let unknownCitationIDs: [String]
    let unsupportedNumbers: [String]
    let lexicalCoverage: Double
    let quotedTextMatches: Bool?
    var passesBasicChecks: Bool {
        unknownCitationIDs.isEmpty && unsupportedNumbers.isEmpty
            && lexicalCoverage >= 0.25 && quotedTextMatches != false
    }
}

enum RAGGrounding {
    static func assess(_ output: String, evidence: [RAGEvidence]) throws -> [RAGClaim] {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw RAGError.invalidInput("생성 결과가 비어 있습니다.") }
        let regex = try NSRegularExpression(pattern: #"^\[(E\d+(?:,E\d+)*)\]\s*(.+)$"#)
        return try lines.enumerated().map { index, line in
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                throw RAGError.invalidInput("생성 문장은 [E0] 내용 형식과 유효한 근거 ID가 필요합니다.")
            }
            let ids = ns.substring(with: match.range(at: 1)).components(separatedBy: ",")
            let text = ns.substring(with: match.range(at: 2))
            let known = evidence.filter { ids.contains($0.id) }
            let source = known.map { $0.chunk.caseNumber + "\n" + $0.chunk.text }.joined(separator: "\n")
            let normalizedSource = normalize(source)
            let grams = bigrams(normalize(text))
            let coverage = grams.isEmpty ? 0 : Double(grams.filter { normalizedSource.contains($0) }.count) / Double(grams.count)
            let numbers = try matches(#"\d+(?:[.,]\d+)*"#, in: text)
            let sourceNumbers = Set(try matches(#"\d+(?:[.,]\d+)*"#, in: source))
            let quotes = try matches(#"“([^”]+)”|"([^"]+)""#, in: text, capture: true)
            return RAGClaim(
                id: index, text: text, citationIDs: ids,
                unknownCitationIDs: ids.filter { id in !evidence.contains { $0.id == id } },
                unsupportedNumbers: numbers.filter { !sourceNumbers.contains($0) },
                lexicalCoverage: coverage,
                quotedTextMatches: quotes.isEmpty ? nil : quotes.allSatisfy { normalizedSource.contains(normalize($0)) }
            )
        }

    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func bigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= 2 else { return Set(value.isEmpty ? [] : [value]) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    private static func matches(_ pattern: String, in text: String, capture: Bool = false) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            guard capture else { return ns.substring(with: match.range) }
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            return ns.substring(with: range)
        }
    }
}

struct RAGGenerationTrace: Codable {
    let output: String
    let evidence: [RAGEvidence]
    let engine: String
    let model: String?
    let inferenceMS: Double
    let attempts: Int
    let promptCharacters: Int
    let failureReason: String?
}

enum RAGAnalysisTask: String, Codable, CaseIterable, Identifiable {
    case analysis, oxDraft
    var id: String { rawValue }
    var label: String { self == .analysis ? "쟁점 분석" : "근거 기반 OX 초안" }
}

struct RAGQuizDraft: Codable {
    let question: String
    let answer: Bool
    let explanation: String

    static func parse(_ claims: [RAGClaim]) throws -> RAGQuizDraft {
        guard claims.count == 3,
              claims[0].text.hasPrefix("문항:"), claims[1].text.hasPrefix("정답:"),
              claims[2].text.hasPrefix("해설:") else {
            throw RAGError.invalidInput("OX 초안은 인용된 문항·정답·해설 3줄이어야 합니다.")
        }
        let question = String(claims[0].text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let answer = String(claims[1].text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let explanation = String(claims[2].text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, ["O", "X"].contains(answer), !explanation.isEmpty else {
            throw RAGError.invalidInput("OX 초안의 문항·정답(O/X)·해설을 확인해 주세요.")
        }
        return RAGQuizDraft(question: question, answer: answer == "O", explanation: explanation)
    }
}
