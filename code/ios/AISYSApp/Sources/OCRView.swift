import SwiftUI
import PhotosUI
import Vision
import SwiftData

struct OCRView: View {
    @EnvironmentObject private var runtime: AppRuntimeState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var recognizedText = ""
    @State private var selectedPhotoCount = 0
    @State private var caseIdentifierInput = ""
    @State private var isRecognizing = false
    @State private var isExtractingIR = false
    @State private var ocrError: String?
    @State private var navigateToSummary = false
    @StateObject private var summaryViewModel = CaseSummaryViewModel()

    var body: some View {
        ScrollView {
                VStack(spacing: 20) {
                    Text("판례 스캔")
                        .font(.largeTitle.bold())
                    Text("공부 중 본 판례 사진을 담아두면 자동으로 요약·정리되어 한 켠에 쌓입니다.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.blue.opacity(0.1))
                        .frame(height: 220)
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.text.viewfinder")
                                    .font(.system(size: 46))
                                    .foregroundStyle(.blue)
                                if isRecognizing {
                                    ProgressView()
                                    Text("이미지에서 글자를 읽는 중...").foregroundStyle(.secondary)
                                } else if isExtractingIR {
                                    ProgressView()
                                    Text("핵심 키워드를 정리하는 중...").foregroundStyle(.secondary)
                                } else {
                                    Text("사진을 선택하면 분석을 시작합니다")
                                        .foregroundStyle(.secondary)
                                    if selectedPhotoCount > 0 {
                                        Text("선택된 이미지: \(selectedPhotoCount)장")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 20, matching: .images) {
                        Label("사진 여러 장 선택", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRecognizing || isExtractingIR)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("판례 이름/번호")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("예: 2024다311181 또는 사건명", text: $caseIdentifierInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isRecognizing || isExtractingIR)
                        Text("입력하면 메모용 식별자로 쓰입니다. 비워두면 본문 핵심어로 「〇〇 사건」 형태 이름이 자동 생성됩니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let ocrError {
                        Text(ocrError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !recognizedText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("인식 결과 (\(recognizedText.count)자)")
                                .font(.headline)
                            Text(recognizedText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button {
                            Task { await processOCRText() }
                        } label: {
                            Label("판례 분석 시작", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(isExtractingIR)
                    }
                }
                .padding()
            }
            .navigationTitle("판례 스캔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .bold))
                            Text("뒤로")
                                .font(.system(size: 15))
                        }
                    }
                    .accessibilityLabel("뒤로 가기")
                }
            }
            .navigationDestination(isPresented: $navigateToSummary) {
                if let ocrCase = runtime.pendingOCRCase {
                    CaseSummaryView(apiCase: ocrCase, viewModel: summaryViewModel)
                }
            }
            .onChange(of: selectedPhotos) { newValue in
                guard !newValue.isEmpty else { return }
                Task { await recognize(items: newValue) }
            }
    }

    // MARK: - OCR

    @MainActor
    private func recognize(items: [PhotosPickerItem]) async {
        isRecognizing = true
        ocrError = nil
        recognizedText = ""
        selectedPhotoCount = items.count
        defer { isRecognizing = false }

        var mergedTexts: [String] = []
        mergedTexts.reserveCapacity(items.count)

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            if let text = try? await recognizeSingleImage(data: data), !text.isEmpty {
                mergedTexts.append(text)
            }
        }

        let merged = mergedTexts.joined(separator: "\n\n")
        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ocrError = "인식된 텍스트가 없습니다. 다른 사진으로 시도해 주세요."
            return
        }

        recognizedText = merged
    }

    private func recognizeSingleImage(data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR"]

            let handler = VNImageRequestHandler(data: data)
            try handler.perform([request])
            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            if text.isEmpty {
                throw OCRRecognitionError.emptyText
            }
            return text
        }.value
    }

    private enum OCRRecognitionError: Error {
        case emptyText
    }

    // MARK: - IR 추출 → 임시 APICase 생성 → 암기수첩 이동

    @MainActor
    private func processOCRText() async {
        isExtractingIR = true
        ocrError = nil
        defer { isExtractingIR = false }

        // 백엔드 /ir/extract 호출 (실패 시 로컬 폴백)
        var keywords: [String] = []
        var keySentences = ""
        var domain = "general_legal"
        var studyFocus: [String] = []

        do {
            let result = try await NetworkService.shared.irExtract(text: recognizedText)
            keywords = result.keywords
            keySentences = result.keySentences
            if let d = result.domain, !d.isEmpty {
                domain = d
            }
            studyFocus = result.studyFocus ?? []
        } catch {
            // 백엔드 없을 때: OCR 텍스트 앞 500자를 keySentences로 사용
            // 폴백: 상태바·URL 등 잡음 라인을 제거하고 의미있는 문장만 추출
            let meaningfulLines = recognizedText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    line.count > 10 &&
                    !line.contains("portal.scourt") &&
                    !line.contains("http") &&
                    !line.allSatisfy({ $0.isNumber || $0 == ":" })
                }
            keySentences = meaningfulLines.prefix(8).joined(separator: " ")
            keywords = extractLocalKeywords(from: recognizedText)
            studyFocus = [
                "핵심 쟁점-결론-시험포인트 순서로 1회 요약",
                "헷갈리는 문장은 OX로 바꿔 반복 확인"
            ]
        }

        // OCR 원문 잡음을 줄여 요약 카드와 OX 품질을 올립니다.
        keySentences = refineIRSentences(keySentences, sourceText: recognizedText)
        if keywords.isEmpty {
            keywords = extractLocalKeywords(from: keySentences.isEmpty ? recognizedText : keySentences)
        }
        // IR API 키워드에도 시간/장소 표기를 같은 규칙으로 제거 ("00경부터", "08경")
        keywords = sanitizeKeywords(keywords)

        // 학습카드 품질을 위해 OCR 텍스트에서 사건 정보(번호·사건명·도메인·쟁점·결론)를 분리 추출
        let digest = extractCaseDigest(rawText: recognizedText, keySentences: keySentences, keywords: keywords)

        // 사건번호/사건명 결정: 사용자 입력 > [···] 박타이틀 > 자동 생성(키워드 기반) > 자동 식별자
        // 사용자 입력은 메모용 식별자(예: "2024다311181")로만 쓰고, 실제 표시 이름은 판례 내용을 반영한 자동 이름 우선
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let manualIdentifier = caseIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCaseName = deriveAutoCaseName(
            keywords: keywords,
            domainLabel: digest.domainLabel,
            issueSentence: digest.issueSentence
        )
        let bracketSubjectName = digest.caseSubject.isEmpty
            ? ""
            : (digest.caseSubject.hasSuffix("사건") || digest.caseSubject.hasSuffix("판례")
                ? digest.caseSubject
                : digest.caseSubject + " 사건")

        let ocrCaseNumber: String
        let ocrCaseName: String
        if !manualIdentifier.isEmpty && looksLikeCaseNumber(manualIdentifier) {
            // 사용자가 사건번호를 직접 입력한 경우: 식별자는 그대로, 이름은 자동 생성 우선
            ocrCaseNumber = manualIdentifier
            ocrCaseName = !bracketSubjectName.isEmpty ? bracketSubjectName
                        : (!autoCaseName.isEmpty ? autoCaseName : manualIdentifier)
        } else if !manualIdentifier.isEmpty {
            // 사용자가 임의 메모명(예: "테스트2")을 입력한 경우: 식별자로는 쓰되, 사건명은 자동 이름 우선
            ocrCaseNumber = digest.caseNumber.isEmpty ? manualIdentifier : digest.caseNumber
            ocrCaseName = !bracketSubjectName.isEmpty ? bracketSubjectName
                        : (!autoCaseName.isEmpty ? autoCaseName : manualIdentifier)
        } else if !digest.caseNumber.isEmpty {
            ocrCaseNumber = digest.caseNumber
            ocrCaseName = !bracketSubjectName.isEmpty ? bracketSubjectName
                        : (!autoCaseName.isEmpty ? autoCaseName : digest.caseNumber)
        } else {
            let auto = "OCR-\(formatter.string(from: now))"
            ocrCaseNumber = auto
            ocrCaseName = !bracketSubjectName.isEmpty ? bracketSubjectName
                        : (!autoCaseName.isEmpty ? autoCaseName : auto)
        }

        // examPoints — 단순 조항 나열 대신 "도메인 학습 가이드 + 핵심 본문 키워드" 합성으로 가독성 개선
        let bodyKeywords = keywords.filter { kw in
            // 조문/사건번호 형태(숫자가 들어가는 정형신호)는 시험 포인트 텍스트에서 제외
            kw.range(of: #"(제\d+조|\d+[가-힣]\d+|\d{2,4}\.)"#, options: .regularExpression) == nil
        }
        let examPointText: String = {
            let head = studyFocus.first ?? "핵심 쟁점·결론을 묶어 암기"
            let kwTail = bodyKeywords.prefix(4).joined(separator: ", ")
            if kwTail.isEmpty { return head }
            return "\(head) — 본문 키워드: \(kwTail)"
        }()

        let ocrCase = APICase(
            id: "ocr-\(Int(now.timeIntervalSince1970))",
            caseNumber: ocrCaseNumber,
            caseName: ocrCaseName,
            courtName: digest.court.isEmpty ? "스캔 문서" : digest.court,
            subject: digest.domainLabel.isEmpty
                ? bodyKeywords.prefix(3).joined(separator: " · ")
                : "\(digest.domainLabel) · " + bodyKeywords.prefix(2).joined(separator: " · "),
            issueSummary: digest.issueSentence,
            holdingSummary: digest.holdingSentence,
            examPoints: examPointText,
            sourceUrl: nil
        )

        // 1B Llama 분류 트리로 "과목 > 카테고리 > 세부유형" 경로 산출
        // 결과는 subject 필드 prefix로 주입 (실패 시 기존 subject 유지)
        let classifyText = [digest.issueSentence, digest.holdingSentence, keySentences]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let taxonomyPath = await summaryViewModel.classifyByTaxonomy(text: classifyText)
        let finalCase: APICase
        if !taxonomyPath.isEmpty {
            finalCase = APICase(
                id: ocrCase.id,
                caseNumber: ocrCase.caseNumber,
                caseName: ocrCase.caseName,
                courtName: ocrCase.courtName,
                subject: taxonomyPath + (ocrCase.subject.isEmpty ? "" : " · " + ocrCase.subject),
                issueSummary: ocrCase.issueSummary,
                holdingSummary: ocrCase.holdingSummary,
                examPoints: ocrCase.examPoints,
                sourceUrl: ocrCase.sourceUrl
            )
        } else {
            finalCase = ocrCase
        }

        // ViewModel IR 결과 주입 (재생성 없이 기존 인스턴스 재사용)
        summaryViewModel.injectIRResult(
            keywords: keywords,
            keySentences: keySentences,
            domain: domain,
            studyFocus: studyFocus
        )

        // SwiftData에 영구 저장
        let record = ScannedCase(
            ocrRawText: recognizedText,
            keywords: keywords,
            keySentences: keySentences,
            caseName: ocrCaseNumber
        )
        modelContext.insert(record)

        runtime.pendingOCRCase = finalCase
        navigateToSummary = true
    }

    // MARK: - 로컬 폴백 키워드 추출 (백엔드 없을 때)

    private func extractLocalKeywords(from text: String) -> [String] {
        // 백엔드 미접속 시 OCR 키워드가 빈약하면 학습 보조 카드 전체 품질이 떨어지므로
        // 1) 조문/사건번호 등 정형 신호를 우선 잡고
        // 2) 한국어 조사·어미를 제거해 명사형 키워드로 정규화한 뒤
        // 3) 빈도 + 법률 힌트 가산점으로 정렬한다.
        let stopwords: Set<String> = [
            "이", "가", "은", "는", "을", "를", "의", "에", "에서", "로", "으로",
            "와", "과", "도", "한", "하여", "하고", "있다", "없다", "된다", "한다",
            "것", "수", "바", "때", "경우", "또는", "및", "그", "이러한"
        ]
        let legalHints: [String] = [
            "위법", "적법", "고의", "과실", "구성요건", "책임", "정당방위",
            "영장", "압수", "수색", "증거", "공소", "기소", "무죄", "유죄",
            "체포", "구속", "위헌", "합헌", "기본권", "과잉금지", "최소침해",
            "위원회", "징계", "행정처분", "취소", "재량", "처분", "결정", "판결"
        ]

        let suffixes: [String] = [
            "으로서", "으로써", "이라고", "라고", "이라는", "라는",
            "에서", "으로", "에게",
            "하였다", "되었다", "한다", "했다", "되며", "하며", "하고", "되고",
            "하여", "되어", "하자", "하는", "되는", "있는", "없는",
            "다고", "는지", "은지", "하는지", "되는지", "한다고", "된다고",
            "이라는", "라는", "다는",
            "은", "는", "이", "가", "을", "를", "의", "에", "도", "만",
            "와", "과", "로"
        ].sorted { $0.count > $1.count }

        func stripEndings(_ token: String) -> String {
            guard token.count >= 3 else { return token }
            for s in suffixes where token.hasSuffix(s) && (token.count - s.count) >= 2 {
                return String(token.dropLast(s.count))
            }
            return token
        }

        var ranked: [String] = []
        var seen: Set<String> = []

        // 1) 조문 / 사건번호 / 법원명 정형 패턴
        let formalPatterns: [String] = [
            #"제\s*\d+\s*조(?:\s*의\s*\d+)?(?:\s*제\s*\d+\s*항)?(?:\s*제\s*\d+\s*호)?"#,
            #"\d{2,4}\s*[가-힣]{1,3}\s*\d+"#,
            #"(?:대법원|헌법재판소|고등법원|지방법원|가정법원|행정법원|특허법원)"#
        ]
        for pattern in formalPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                regex.enumerateMatches(in: text, range: range) { match, _, _ in
                    guard let r = match?.range, let swiftR = Range(r, in: text) else { return }
                    let raw = String(text[swiftR]).replacingOccurrences(of: " ", with: "")
                    if !raw.isEmpty && !seen.contains(raw) {
                        seen.insert(raw)
                        ranked.append(raw)
                    }
                }
            }
        }

        // 2) 한글 토큰 추출 + 어미 제거
        let words = text
            .components(separatedBy: .init(charactersIn: " \n\t.,()[]「」『』《》〈〉·:;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { token -> String? in
                let cleaned = stripEndings(token)
                guard cleaned.count >= 2,
                      cleaned.count <= 14,
                      !stopwords.contains(cleaned),
                      cleaned.unicodeScalars.contains(where: { $0.value >= 0xAC00 && $0.value <= 0xD7A3 })
                else { return nil }
                // 시간/장소 표기 노이즈 제외 ("00경부터", "08경", "경부터")
                if cleaned.range(of: #"^\d+경"#, options: .regularExpression) != nil { return nil }
                if cleaned.hasPrefix("경부터") || cleaned.hasPrefix("경까지") { return nil }
                // 순수 숫자+한자 1자 조합 ("00경", "5월") 제외
                if cleaned.range(of: #"^\d{1,3}[가-힣]{1,2}$"#, options: .regularExpression) != nil,
                   !cleaned.hasSuffix("조") && !cleaned.hasSuffix("항") && !cleaned.hasSuffix("호") {
                    return nil
                }
                return cleaned
            }

        var freq: [String: Int] = [:]
        for w in words { freq[w, default: 0] += 1 }

        let scored = freq.map { (term, count) -> (String, Double) in
            var s = Double(count)
            if legalHints.contains(where: { term.contains($0) }) { s += 1.8 }
            if term.hasSuffix("죄") || term.hasSuffix("조") || term.hasSuffix("법")
               || term.hasSuffix("권") || term.hasSuffix("처분") || term.hasSuffix("결정") {
                s += 1.0
            }
            if term.hasSuffix("하") || term.hasSuffix("되") { s -= 0.5 }
            return (term, s)
        }
        .sorted { $0.1 > $1.1 }

        for (term, _) in scored {
            if !seen.contains(term) {
                seen.insert(term)
                ranked.append(term)
            }
            if ranked.count >= 10 { break }
        }
        return ranked
    }

    private func refineIRSentences(_ keySentences: String, sourceText: String) -> String {
        let raw = keySentences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sourceText : keySentences

        let parts = raw
            .components(separatedBy: CharacterSet(charactersIn: "\n。.!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { s in
                s.count >= 12 &&
                !s.contains("portal.scourt") &&
                !s.contains("http") &&
                !s.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" })
            }

        var seen: Set<String> = []
        var cleaned: [String] = []

        for part in parts {
            // 공백/페이지 표시는 정리하되 "제○조"는 시험 핵심 키워드이므로 보존한다.
            let normalized = part
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"^[\s\-•·]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*[-–—]\s*\d+\s*[-–—]\s*$"#, with: "", options: .regularExpression) // 페이지 번호 -1-
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard normalized.count >= 10, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            cleaned.append(normalized)
            if cleaned.count >= 4 { break }
        }

        // 한국어 종결어미 직후에서 자르고 마무리한다.
        return cleaned
            .map { sentence -> String in
                let trimmed = String(sentence.prefix(140))
                if trimmed.hasSuffix("다") || trimmed.hasSuffix("요") || trimmed.hasSuffix(".") {
                    return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
                }
                return trimmed + "…"
            }
            .joined(separator: " ")
    }

    // MARK: - 사건 디지스트 추출 (학습카드 품질용)

    /// OCR 원문에서 분리 추출한 사건 정보. 모든 필드는 학습카드에 즉시 사용 가능한 짧은 형태이다.
    private struct CaseDigest {
        var caseNumber: String          // 2025마8671 / 2024다311181
        var caseSubject: String         // 권리행사최고및담보취소 / 영업정지처분취소
        var court: String               // 대법원 / 헌법재판소
        var date: String                // 2026.4.10.
        var domain: String              // civil_procedure / criminal / constitutional / administrative / police_committees / general_legal
        var domainLabel: String         // 민사 / 형사 / 헌법 / 행정 / 경찰위 / 일반
        var issueSentence: String       // "...여부." 한 문장
        var holdingSentence: String     // "...해당하지 않는다." 한 문장
    }

    /// 한국어 종결 문자열 모음 (디지스트 + 폴백 양쪽에서 공유)
    private static let koreanTerminalEndings = ["다.", "요.", "임.", "음.", "다 ", "였다.", "한다.", "된다.", "이다.", "라고 한다.", "한 사례이다.", "본 판례이다.", "?", "!"]

    /// 도메인 후보와 키워드 매핑. 점수가 가장 높은 항목을 도메인으로 채택한다.
    private static let domainKeywordMap: [(domain: String, label: String, hints: [String])] = [
        ("criminal_law", "형법", ["고의", "과실", "정당방위", "긴급피난", "구성요건", "공범", "정범", "교사범", "방조범", "절도", "강도", "사기", "횡령", "배임", "상해", "폭행", "살인", "강간", "협박", "감금", "주거침입", "재물", "유죄", "무죄"]),
        ("criminal_procedure_evidence", "형소법", ["영장", "체포", "구속", "압수", "수색", "검증", "긴급체포", "현행범", "공소", "기소", "공판", "증거능력", "위법수집증거", "전문법칙", "탄핵증거", "자백배제법칙", "임의수사", "강제수사"]),
        ("constitutional_law", "헌법", ["기본권", "평등권", "자유권", "참정권", "위헌", "합헌", "한정위헌", "헌법불합치", "과잉금지", "비례원칙", "본질적", "최소침해", "법익균형성", "수단적합성"]),
        ("administrative_law", "행정법", ["행정처분", "재량", "기속", "재량권", "비례원칙", "신뢰보호", "취소소송", "무효확인", "처분", "행정행위", "공법상", "행정청"]),
        ("police_committees", "경찰위", ["경찰위원회", "국가경찰위원회", "시도자치경찰위원회", "위원장", "부위원장", "의결정족수", "재적위원", "표결권", "직무대행"]),
        ("civil_procedure", "민사", ["가압류", "가처분", "담보공탁", "담보취소", "권리행사최고", "공탁금", "손해배상", "소송비용", "소송요건", "기판력", "재심", "강제집행"]),
    ]

    private func extractCaseDigest(rawText: String, keySentences: String, keywords: [String]) -> CaseDigest {
        var digest = CaseDigest(caseNumber: "", caseSubject: "", court: "", date: "",
                                domain: "general_legal", domainLabel: "", issueSentence: "", holdingSentence: "")

        // 1) 사건번호: 2025마8671 / 2024다311181 / 2022헌마123 형태
        if let r = rawText.range(of: #"\d{2,4}\s*[가-힣]{1,3}\s*\d+"#, options: .regularExpression) {
            digest.caseNumber = String(rawText[r]).replacingOccurrences(of: " ", with: "")
        }

        // 2) 사건명: 첫 번째 [...] 대괄호 안 내용 (공백 압축)
        if let r = rawText.range(of: #"\[[^\]]{2,40}\]"#, options: .regularExpression) {
            var subj = String(rawText[r])
            subj = subj.replacingOccurrences(of: "[", with: "")
            subj = subj.replacingOccurrences(of: "]", with: "")
            subj = subj.replacingOccurrences(of: " ", with: "")
            // 잡음(공YYYY 같은 출처 표기) 제외
            if !subj.hasPrefix("공") && !subj.hasPrefix("미간행") {
                digest.caseSubject = subj
            }
        }

        // 3) 법원명
        if let r = rawText.range(of: #"(대법원|헌법재판소|고등법원|지방법원|행정법원|가정법원|특허법원)"#, options: .regularExpression) {
            digest.court = String(rawText[r])
        }

        // 4) 선고일
        if let r = rawText.range(of: #"\d{4}\.\s*\d{1,2}\.\s*\d{1,2}"#, options: .regularExpression) {
            digest.date = String(rawText[r]).replacingOccurrences(of: " ", with: "")
        }

        // 5) 도메인 — 키워드 + 본문 동시 매칭, 가산점 합산
        let lowerText = rawText
        var bestScore = 0
        for entry in OCRView.domainKeywordMap {
            var score = 0
            for hint in entry.hints {
                if lowerText.contains(hint) { score += 1 }
                if keywords.contains(where: { $0.contains(hint) || hint.contains($0) }) { score += 1 }
            }
            if score > bestScore {
                bestScore = score
                digest.domain = entry.domain
                digest.domainLabel = entry.label
            }
        }
        if bestScore < 2 {
            digest.domain = "general_legal"
            digest.domainLabel = "일반"
        }

        // 6) 쟁점 문장 / 결론 문장 추출
        let sentences = collectCandidateSentences(rawText: rawText, keySentences: keySentences)
        digest.issueSentence = pickIssueSentence(from: sentences) ?? "쟁점 정보를 OCR에서 추출하지 못했다."
        digest.holdingSentence = pickHoldingSentence(from: sentences, issueSentence: digest.issueSentence)
            ?? "결론을 OCR에서 추출하지 못했다. 원문을 확인하라."

        return digest
    }

    /// 사용자가 입력한 문자열이 사건번호 형태인지 판별 (예: "2024다311181", "2022헌마123")
    private func looksLikeCaseNumber(_ s: String) -> Bool {
        return s.range(of: #"^\d{2,4}\s*[가-힣]{1,3}\s*\d+$"#, options: .regularExpression) != nil
    }

    /// OCR 키워드/쟁점 문장에서 의미 있는 "○○ 사건" 형태 사건명을 합성한다.
    /// - 우선순위: (1) 도메인 사전의 법률 용어 키워드 상위 1~2개 → (2) 쟁점 문장의 핵심 명사 → (3) 빈 문자열
    /// - 결과 예: "담보공탁금 사건", "위법수집증거 사건", "재량권 일탈 사건"
    private func deriveAutoCaseName(keywords: [String], domainLabel: String, issueSentence: String) -> String {
        // 도메인 힌트 집합 (모든 도메인의 hints를 평탄화)
        let legalHints: Set<String> = Set(OCRView.domainKeywordMap.flatMap { $0.hints })

        // 1) 키워드 중 법률 용어 우선 추출 (2~10자, 숫자/특수문자 제외)
        let cleanedKeywords: [String] = keywords.compactMap { kw -> String? in
            let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.count <= 12 else { return nil }
            if trimmed.range(of: #"^[\d\s\-_.]+$"#, options: .regularExpression) != nil { return nil }
            // 출처/메타 잡음 제외
            let blacklist: Set<String> = ["판례", "사건", "공보", "미간행", "선고", "판결", "결정", "원심", "원고", "피고", "상고", "항소"]
            if blacklist.contains(trimmed) { return nil }
            return trimmed
        }

        let legalKeywords = cleanedKeywords.filter { kw in
            legalHints.contains(where: { $0 == kw || $0.contains(kw) || kw.contains($0) })
        }

        let primary = legalKeywords.first ?? cleanedKeywords.first
        let secondary: String? = {
            let pool = !legalKeywords.isEmpty ? legalKeywords : cleanedKeywords
            guard pool.count >= 2, let p = primary else { return nil }
            return pool.first(where: { $0 != p && !$0.contains(p) && !p.contains($0) })
        }()

        if let kw1 = primary {
            if let kw2 = secondary {
                return "\(kw1) \(kw2) 사건"
            }
            // 도메인 라벨이 있으면 부가 정보로 활용 ("재량권 행정법 사건"은 어색하므로 도메인은 생략하고 단일 키워드 사용)
            return "\(kw1) 사건"
        }

        // 2) 키워드가 없으면 쟁점 문장에서 첫 명사구 후보를 잘라낸다 (어절 1~2개)
        let issue = issueSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !issue.isEmpty && !issue.hasPrefix("쟁점 정보를") {
            let tokens = issue.split(separator: " ").map(String.init)
            if let firstNoun = tokens.first(where: { $0.count >= 2 && $0.count <= 10 }) {
                let cleaned = firstNoun.replacingOccurrences(of: #"[,\.\(\)\[\]]"#, with: "", options: .regularExpression)
                if !cleaned.isEmpty { return "\(cleaned) 관련 사건" }
            }
        }

        _ = domainLabel // 현재 직접 사용하지 않지만 향후 도메인별 접미사 분기에 사용
        return ""
    }

    /// 학습카드 후보 문장 수집: 줄바꿈/마침표/괄호로 분할하고 잡음을 제거한다.
    private func collectCandidateSentences(rawText: String, keySentences: String) -> [String] {
        let combined = (keySentences.isEmpty ? rawText : keySentences + "\n" + rawText)
        // 한국어/일본어 인용기호, 전각 꺾쇠, 괄호도 모두 문장 경계로 취급
        var normalized = combined
        for sep in ["<", ">", "〈", "〉", "《", "》", "「", "」", "『", "』", "】", "【"] {
            normalized = normalized.replacingOccurrences(of: sep, with: "\n")
        }
        // "문제 된 사건" / "문제된 사건" 뒤는 별도 문장으로 분리 (판례공보 헤더 + 본문이 한 줄에 합쳐진 경우 대비)
        normalized = normalized.replacingOccurrences(of: "문제 된 사건", with: "문제 된 사건.\n")
        normalized = normalized.replacingOccurrences(of: "문제된 사건", with: "문제된 사건.\n")
        // OCR 잘못 띄어쓰기 보정 — 어간과 어미 사이 공백 제거 (보수적으로 빈도 높은 케이스만)
        for pair in [("하 는", "하는"), ("되 는", "되는"), ("이 다", "이다"), ("한 다", "한다"),
                     ("된 다", "된다"), ("하 다", "하다"), ("있 다", "있다"), ("없 다", "없다"),
                     ("있 는", "있는"), ("없 는", "없는"), ("였 다", "였다"), ("이 라", "이라"),
                     ("담보하 는", "담보하는"), ("관 한", "관한"), ("대 한", "대한")] {
            normalized = normalized.replacingOccurrences(of: pair.0, with: pair.1)
        }
        // 줄바꿈 직후가 조사로 시작하는 단편이면 직전 줄과 합친다 ("...담보하\n는 손해..." → "...담보하는 손해...")
        let leadingParticleRegex = #"\n\s*(는|은|이|가|을|를|의|에|에서|에게|도|와|과|로|으로|및|또는)\s"#
        normalized = normalized.replacingOccurrences(of: leadingParticleRegex, with: "$1 ", options: .regularExpression)
        let chunks = normalized
            .components(separatedBy: CharacterSet(charactersIn: "\n。"))
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line -> Bool in
                guard line.count >= 12, line.count <= 220 else { return false }
                if line.contains("http") || line.contains("portal.scourt") { return false }
                if line.contains("판례공보") || line.contains("미간행") { return false }
                if line.range(of: #"^[\s\d\-:]+$"#, options: .regularExpression) != nil { return false }
                // "공YYYY ..." 같은 출처 헤더 라인은 제외
                if line.range(of: #"^\s*공\s*\d{4}"#, options: .regularExpression) != nil { return false }
                // "(2024. 5. 10. 선고 2024도4422 판결)" 같은 인용표기만 단독으로 넘어온 경우 제외
                if line.range(of: #"^[\s\(]*\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?\s*선고"#, options: .regularExpression) != nil { return false }
                if line.range(of: #"^\s*선고\s+\d{2,4}[가-힣]{1,3}\d+\s*판결"#, options: .regularExpression) != nil { return false }
                // OCR이 앞말을 잘라 "게 ", "고 ", "지 ", "서 ", "는 ", "다 " 같은 어미·조사 조각으로 시작하는 문장 거부
                let firstWord = line.prefix(2)
                let leadingFragments: Set<String> = [
                    "게 ", "고 ", "지 ", "서 ", "며 ", "어 ", "아 ", "워 ", "다 ", "라 ", "나 ",
                    "는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "의 ", "에 ", "도 ", "와 ", "과 "
                ]
                if leadingFragments.contains(String(firstWord)) { return false }
                return true
            }
        // 중복 제거
        var seen: Set<String> = []
        var unique: [String] = []
        for s in chunks where !seen.contains(s) {
            seen.insert(s)
            unique.append(s)
        }
        return unique
    }

    /// 쟁점 후보: "여부", "기준", "문제 된", "할 수 있는지", "되는지", "판단", "해당하는지" 포함 문장 우선
    private func pickIssueSentence(from sentences: [String]) -> String? {
        let strong = ["여부", "되는지", "할 수 있는지", "허용되는지", "해당하는지", "문제 된 사건", "문제된 사건"]
        let weak = ["기준", "판단 기준", "판단", "쟁점"]

        // 결과 후처리: 조사·접속사로 시작하는 단편이면 prefix 제거
        func cleanLeading(_ s: String) -> String {
            var out = s
            let leading = ["는 ", "은 ", "이 ", "가 ", "을 ", "를 ", "의 ", "에 ", "도 ", "와 ", "과 ", "로 ", "으로 "]
            for p in leading where out.hasPrefix(p) {
                out = String(out.dropFirst(p.count))
                break
            }
            return out
        }

        if let picked = sentences.first(where: { line in strong.contains(where: { line.contains($0) }) }) {
            return finalizeKoreanSentence(cleanLeading(stripBracketNoise(picked)), limit: 130)
        }
        if let picked = sentences.first(where: { line in weak.contains(where: { line.contains($0) }) }) {
            return finalizeKoreanSentence(cleanLeading(stripBracketNoise(picked)), limit: 130)
        }
        return sentences.first.map { finalizeKoreanSentence(cleanLeading(stripBracketNoise($0)), limit: 130) }
    }

    /// 결론 후보: 결과 동사 우선. 쟁점과 같은 문장이면 다음 후보를 찾는다.
    private func pickHoldingSentence(from sentences: [String], issueSentence: String) -> String? {
        let verdicts = [
            "포함되지 않는다", "포함된다",
            "해당하지 않는다", "해당한다",
            "위법하다", "적법하다",
            "유죄", "무죄",
            "기각한다", "기각", "인용한다", "인용",
            "위반된다", "위반", "위반되지 않는다",
            "허용되지 않는다", "허용된다",
            "위헌", "합헌", "한정위헌", "헌법불합치",
            "파기한다", "파기환송", "환송한다",
            "원심을 파기", "원심을 유지",
            "성립하지 않는다", "성립한다",
            "인정되지 않는다", "인정된다",
            "정당하다", "부당하다",
            "(적극)", "(소극)"  // 판례집 스타일 결론 표기
        ]
        // 1순위: 쟁점 또는 후보 문장 어디에든 (적극)/(소극) 마커가 있으면 합성 결론 사용
        let activeRegex = #"\(\s*적\s*극\s*\)"#
        let passiveRegex = #"\(\s*소\s*극\s*\)"#
        let activeMarker = issueSentence.range(of: activeRegex, options: .regularExpression) != nil
            || sentences.contains { $0.range(of: activeRegex, options: .regularExpression) != nil }
        let passiveMarker = issueSentence.range(of: passiveRegex, options: .regularExpression) != nil
            || sentences.contains { $0.range(of: passiveRegex, options: .regularExpression) != nil }
        if activeMarker {
            return "관련 쟁점이 적극적으로 인정되었다(적극)."
        }
        if passiveMarker {
            return "관련 쟁점이 소극적으로 부정되었다(소극)."
        }
        // 2순위: 쟁점과 다른 본문 중 결론 동사 포함 문장
        let pool = sentences.filter { $0 != issueSentence }
        if let picked = pool.first(where: { line in verdicts.contains(where: { line.contains($0) }) }) {
            return finalizeKoreanSentence(stripBracketNoise(picked), limit: 130)
        }
        // 3순위: 쟁점에 결론 동사가 들어가 있으면 그대로
        if verdicts.contains(where: { issueSentence.contains($0) }) {
            return finalizeKoreanSentence(issueSentence, limit: 130)
        }
        // 결론 후보 없음 — nil 반환 (호출부 placeholder)
        return nil
    }

    /// `[ ... ]` 같은 출처/제목 잡음과 페이지 마커 제거 — 학습카드용 본문 정제
    private func stripBracketNoise(_ text: String) -> String {
        var s = text
        // 닫힌 대괄호: [ ... ] 형태 (길이 제한 없음, 사건명 전체 제거 가능하도록)
        s = s.replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
        // OCR이 닫는 ] 를 인식 못한 경우: [공YYYY ... 또는 [공보 ... 끝까지 제거
        s = s.replacingOccurrences(of: #"\[\s*공\s*\d{2,4}.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[공보[^\]]*$"#, with: "", options: .regularExpression)
        // 미닫힌 [ 상황 — 사건명이 "[ 강제추행·..." 식으로 잘려 넘어온 경우 있음. ] 없으면 끝까지 제거
        if s.contains("[") && !s.contains("]") {
            s = s.replacingOccurrences(of: #"\[[^\[]*$"#, with: "", options: .regularExpression)
        }
        // 전각 꺾쇠 안의 출처 표기 〉 / 〈 잔여 문자
        s = s.replacingOccurrences(of: "〉", with: " ")
        s = s.replacingOccurrences(of: "〈", with: " ")
        // "(2024. 5. 10. 선고 2024도4422 판결)" 완전 형
        s = s.replacingOccurrences(of: #"\(\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?\s*선고\s*\d{2,4}[가-힣]{1,3}\d+\s*판결\)"#, with: "", options: .regularExpression)
        // OCR 미닫힌 인용: "선고 2025도4422 판결" / "...선고 ... 판결" 잔재 패턴
        s = s.replacingOccurrences(of: #"선고\s+\d{2,4}[가-힣]{1,3}\d+\s*판결"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"-\s*\d+\s*-"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// IR API가 돌려준 키워드에서 시간/장소 표기 같은 경찰고시용으로 부적절한 항목을 걸러낸다.
    private func sanitizeKeywords(_ keywords: [String]) -> [String] {
        return keywords.compactMap { kw -> String? in
            let t = kw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { return nil }
            // "00경부터", "08경", "경부터", "경까지"
            if t.range(of: #"^\d+경"#, options: .regularExpression) != nil { return nil }
            if t.hasPrefix("경부터") || t.hasPrefix("경까지") { return nil }
            // 수자+한자 1-2자 대부분 시간/날짜 잘린 결과 — 조/항/호는 유지
            if t.range(of: #"^\d{1,3}[가-힣]{1,2}$"#, options: .regularExpression) != nil,
               !t.hasSuffix("조") && !t.hasSuffix("항") && !t.hasSuffix("호") {
                return nil
            }
            return t
        }
    }

    /// 한국어 문장을 종결어미 직후에서 자르고, 마무리 표시(. 또는 …)를 붙인다.
    private func finalizeKoreanSentence(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else {
            if collapsed.hasSuffix(".") || collapsed.hasSuffix("…") { return collapsed }
            if collapsed.hasSuffix("다") || collapsed.hasSuffix("요") { return collapsed + "." }
            return collapsed.isEmpty ? collapsed : collapsed + "…"
        }
        let snippet = String(collapsed.prefix(limit))
        let endings = ["다.", "다 ", "요.", "다고 한다.", "였다.", "한다.", "된다.", "이다."]
        var bestIdx: String.Index? = nil
        for ending in endings {
            if let r = snippet.range(of: ending, options: .backwards) {
                if bestIdx == nil || r.upperBound > bestIdx! { bestIdx = r.upperBound }
            }
        }
        if let idx = bestIdx,
           snippet.distance(from: snippet.startIndex, to: idx) >= max(20, limit / 3) {
            return String(snippet[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let space = snippet.range(of: " ", options: .backwards),
           snippet.distance(from: snippet.startIndex, to: space.lowerBound) >= max(20, limit / 3) {
            return String(snippet[..<space.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return snippet.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
